/// A DatabasePool grants concurrent accesses to an SQLite database.
public final class DatabasePool {
    
    // MARK: - Initializers
    
    /// Opens the SQLite database at path *path*.
    ///
    ///     let dbPool = try DatabasePool(path: "/path/to/database.sqlite")
    ///
    /// Database connections get closed when the database pool gets deallocated.
    ///
    /// - parameters:
    ///     - path: The path to the database file.
    ///     - configuration: A configuration.
    ///     - maximumReaderCount: The maximum number of readers. Default is 5.
    /// - throws: A DatabaseError whenever an SQLite error occurs.
    public convenience init(path: String, configuration: Configuration = Configuration(), maximumReaderCount: Int = 5) throws {
        precondition(maximumReaderCount > 1, "maximumReaderCount must be at least 1")
        
        // Shared database schema cache
        let databaseSchemaCache = SharedDatabaseSchemaCache()
        
        // Writer
        var writerConfig = configuration
        writerConfig.readonly = false
        let writer = try SerializedDatabase(
            path: path,
            configuration: writerConfig,
            schemaCache: databaseSchemaCache)
        
        // Activate WAL Mode
        let mode = writer.inDatabase { db in
            String.fetchOne(db, "PRAGMA journal_mode=WAL")
        }
        guard mode == "wal" else {
            throw DatabaseError(message: "could not activate WAL Mode at path: \(path)")
        }
        
        // Readers
        var readerConfig = configuration
        readerConfig.readonly = true
        readerConfig.defaultTransactionKind = .Deferred

        self.init(path: path, readerConfiguration: readerConfig, maximumReaderCount: maximumReaderCount, databaseSchemaCache: databaseSchemaCache, writer: writer)
    }
    
    
    // MARK: - Database access
    
    /// Synchronously executes a read-only block in the database, and returns
    /// its result.
    ///
    ///     let persons = dbPool.read { db in
    ///         Person.fetch(...)
    ///     }
    ///
    /// This method is *not* reentrant.
    ///
    /// - parameter block: A block that accesses the database.
    /// - throws: The error thrown by the block.
    public func read<T>(block: (db: Database) throws -> T) rethrows -> T {
        // Wrap the read in a DEFERRED transaction.
        //
        // This prevents the writer to sneak in between two selects:
        //
        //      Thread 1                            Thread 2
        //      BEGIN DEFERRED TRANSACTION
        //      SELECT COUNT(*) FROM items -> 0
        //                                          INSERT INTO items...
        //      SELECT COUNT(*) FROM items -> 0 (invisible insert)
        //      COMMIT
        //
        // Without the transaction, we would get:
        //
        //      Thread 1                            Thread 2
        //      SELECT COUNT(*) FROM items -> 0
        //                                          INSERT INTO items...
        //      SELECT COUNT(*) FROM items -> 1 (visible insert)
        //
        // See DatabasePoolTests.testReaderIsolation().
        
        return try readerPool.get { reader in
            try reader.inDatabase { db in
                var result: T? = nil
                try db.inTransaction(.Deferred) {
                    result = try block(db: db)
                    return .Commit
                }
                return result!
            }
        }
    }
    
    /// Synchronously executes an update block in the database, and returns
    /// its result.
    ///
    ///     dbPool.write { db in
    ///         db.execute(...)
    ///     }
    ///
    /// This method is *not* reentrant.
    ///
    /// - parameter block: A block that accesses the database.
    /// - throws: The error thrown by the block.
    public func write(block: (db: Database) throws -> Void) rethrows {
        try writer.inDatabase(block)
    }
    
    /// Synchronously executes a block in the database, wrapped inside a
    /// transaction.
    ///
    /// If the block throws an error, the transaction is rollbacked and the
    /// error is rethrown.
    ///
    ///     try dbPool.writeInTransaction { db in
    ///         db.execute(...)
    ///         return .Commit
    ///     }
    ///
    /// This method is *not* reentrant.
    ///
    /// - parameters:
    ///     - kind: The transaction type (default nil). If nil, the transaction
    ///       type is configuration.defaultTransactionKind, which itself
    ///       defaults to .Immediate. See https://www.sqlite.org/lang_transaction.html
    ///       for more information.
    ///     - block: A block that executes SQL statements and return either
    ///       .Commit or .Rollback.
    /// - throws: The error thrown by the block.
    public func writeInTransaction(kind: TransactionKind? = nil, _ block: (db: Database) throws -> TransactionCompletion) rethrows {
        try writer.inDatabase { db in
            try db.inTransaction(kind) {
                try block(db: db)
            }
        }
    }
    
    
    // MARK: - WAL Management
    
    /// Runs a WAL checkpoint
    ///
    /// See https://www.sqlite.org/wal.html and
    /// https://www.sqlite.org/c3ref/wal_checkpoint_v2.html) for
    /// more information.
    ///
    /// - parameter kind: The checkpoint mode (default passive)
    public func checkpoint(kind: CheckpointMode = .Passive) throws {
        try writer.inDatabase { db in
            // TODO: read https://www.sqlite.org/c3ref/wal_checkpoint_v2.html and
            // check whether we need a busy handler on writer and/or readers.
            let code = sqlite3_wal_checkpoint_v2(db.sqliteConnection, nil, kind.rawValue, nil, nil)
            guard code == SQLITE_OK else {
                throw DatabaseError(code: code, message: db.lastErrorMessage, sql: nil)
            }
        }
    }
    
    
    // MARK: - Memory management
    
    /// Free as much memory as possible.
    ///
    /// This method blocks the current thread until all database accesses are completed.
    /// (TODO: test this assertion, and also that all readers connections are closed).
    public func releaseMemory() {
        writer.inDatabase { db in
            db.releaseMemory()
        }
        
        readerPool.forEach { reader in
            reader.inDatabase { db in
                db.releaseMemory()
            }
        }
        
        readerPool.clear()
    }
    
    
    // MARK: - Not public
    
    private let writer: SerializedDatabase
    private let readerPool: Pool<SerializedDatabase>
    
    private var functions = Set<DatabaseFunction>()
    private var collations = Set<DatabaseCollation>()
    
    private init(path: String, readerConfiguration: Configuration = Configuration(), maximumReaderCount: Int, databaseSchemaCache: DatabaseSchemaCacheType, writer: SerializedDatabase) {
        self.writer = writer
        self.readerPool = Pool<SerializedDatabase>(maximumCount: maximumReaderCount)
        
        readerPool.makeElement = { [unowned self] in
            let serializedDatabase = try! SerializedDatabase(
                path: path,
                configuration: readerConfiguration,
                schemaCache: databaseSchemaCache)
            
            serializedDatabase.inDatabase { db in
                for function in self.functions {
                    db.addFunction(function)
                }
                for collation in self.collations {
                    db.addCollation(collation)
                }
            }
            
            return serializedDatabase
        }
    }
}

// The available [checkppint modes](https://www.sqlite.org/c3ref/wal_checkpoint_v2.html).
public enum CheckpointMode: Int32 {
    case Passive = 0    // SQLITE_CHECKPOINT_PASSIVE
    case Full = 1       // SQLITE_CHECKPOINT_FULL
    case Restart = 2    // SQLITE_CHECKPOINT_RESTART
    case Truncate = 3   // SQLITE_CHECKPOINT_TRUNCATE
}


// =========================================================================
// MARK: - Functions

extension DatabasePool {
    
    /// Add or redefine an SQL function.
    ///
    ///     let fn = DatabaseFunction("succ", argumentCount: 1) { databaseValues in
    ///         let dbv = databaseValues.first!
    ///         guard let int = dbv.value() as Int? else {
    ///             return nil
    ///         }
    ///         return int + 1
    ///     }
    ///     dbPool.addFunction(fn)
    ///     dbPool.read { db in
    ///         Int.fetchOne(db, "SELECT succ(1)") // 2
    ///     }
    public func addFunction(function: DatabaseFunction) {
        functions.remove(function)
        functions.insert(function)
        
        writer.inDatabase { db in
            db.addFunction(function)
        }
        
        readerPool.forEach { reader in
            reader.inDatabase { db in
                db.addFunction(function)
            }
        }
    }
    
    /// Remove an SQL function.
    public func removeFunction(function: DatabaseFunction) {
        functions.remove(function)
        
        writer.inDatabase { db in
            db.removeFunction(function)
        }
        
        readerPool.forEach { reader in
            reader.inDatabase { db in
                db.removeFunction(function)
            }
        }
    }
}


// =========================================================================
// MARK: - Collations

extension DatabasePool {
    
    /// Add or redefine a collation.
    ///
    ///     let collation = DatabaseCollation("localized_standard") { (string1, string2) in
    ///         return (string1 as NSString).localizedStandardCompare(string2)
    ///     }
    ///     dbPool.addCollation(collation)
    ///     dbPool.write { db in
    ///         try db.execute("CREATE TABLE files (name TEXT COLLATE LOCALIZED_STANDARD")
    ///     }
    public func addCollation(collation: DatabaseCollation) {
        collations.remove(collation)
        collations.insert(collation)
        
        writer.inDatabase { db in
            db.addCollation(collation)
        }
        
        readerPool.forEach { reader in
            reader.inDatabase { db in
                db.addCollation(collation)
            }
        }
    }
    
    /// Remove a collation.
    public func removeCollation(collation: DatabaseCollation) {
        collations.remove(collation)
        
        writer.inDatabase { db in
            db.removeCollation(collation)
        }
        
        readerPool.forEach { reader in
            reader.inDatabase { db in
                db.removeCollation(collation)
            }
        }
    }
}