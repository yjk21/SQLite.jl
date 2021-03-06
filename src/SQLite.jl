module SQLite

using Compat

export NULL, SQLiteDB, SQLiteStmt, ResultSet,
execute, query, tables, indices, columns, droptable, dropindex,
create, createindex, append, deleteduplicates

import Base: ==, show, convert, bind, close

type SQLiteException <: Exception
    msg::AbstractString
end

include("consts.jl")
include("api.jl")

# Custom NULL type
immutable NullType end
const NULL = NullType()
show(io::IO,::NullType) = print(io,"NULL")

# internal wrapper type to, in-effect, mark something which has been serialized
immutable Serialization
    object
end

type ResultSet
    colnames
    values::Vector{Any}
end
==(a::ResultSet,b::ResultSet) = a.colnames == b.colnames && a.values == b.values
include("show.jl")
convert(::Type{Matrix},a::ResultSet) = [a[i,j] for i=1:size(a,1), j=1:size(a,2)]

type SQLiteDB{T<:AbstractString}
    file::T
    handle::Ptr{Void}
    changes::Int
end
SQLiteDB(file,handle) = SQLiteDB(file,handle,0)

include("UDF.jl")
export @sr_str, @register, register


function changes(db::SQLiteDB)
    new_tot = sqlite3_total_changes(db.handle)
    diff = new_tot - db.changes
    db.changes = new_tot
    return ResultSet(["Rows Affected"],Any[Any[diff]])
end

#TODO: Support sqlite3_open_v2
# Normal constructor from filename
sqliteopen(file,handle) = sqlite3_open(file,handle)
sqliteopen(file::UTF16String,handle) = sqlite3_open16(file,handle)
sqliteerror() = throw(SQLiteException(bytestring(sqlite3_errmsg())))
sqliteerror(db) = throw(SQLiteException(bytestring(sqlite3_errmsg(db.handle))))

function SQLiteDB(file::AbstractString="";UTF16::Bool=false)
    handle = [C_NULL]
    utf = UTF16 ? utf16 : utf8
    file = isempty(file) ? file : expanduser(file)
    if @OK sqliteopen(utf(file),handle)
        db = SQLiteDB(utf(file),handle[1])
        register(db, regexp, nargs=2)
        finalizer(db,close)
        return db
    else # error
        sqlite3_close(handle[1])
        sqliteerror()
    end
end

function close{T}(db::SQLiteDB{T})
    db.handle == C_NULL && return
    # ensure SQLiteStmts are finalised
    gc()
    @CHECK db sqlite3_close(db.handle)
    db.handle = C_NULL
    return
end

type SQLiteStmt{T}
    db::SQLiteDB{T}
    handle::Ptr{Void}
    sql::T
end

sqliteprepare(db,sql,stmt,null) = 
@CHECK db sqlite3_prepare_v2(db.handle,utf8(sql),stmt,null)
sqliteprepare(db::SQLiteDB{UTF16String},sql,stmt,null) = 
@CHECK db sqlite3_prepare16_v2(db.handle,utf16(sql),stmt,null)

function SQLiteStmt{T}(db::SQLiteDB{T},sql::AbstractString)
    handle = [C_NULL]
    sqliteprepare(db,sql,handle,[C_NULL])
    stmt = SQLiteStmt(db,handle[1],convert(T,sql))
    finalizer(stmt, close)
    return stmt
end

function close(stmt::SQLiteStmt)
    stmt.handle == C_NULL && return
    @CHECK stmt.db sqlite3_finalize(stmt.handle)
    stmt.handle = C_NULL
    return
end

# bind a row to nameless parameters
function bind(stmt::SQLiteStmt, values::Vector)
    nparams = sqlite3_bind_parameter_count(stmt.handle)
    @assert nparams == length(values) "you must provide values for all placeholders"
    for i in 1:nparams
        @inbounds bind(stmt, i, values[i])
    end
end
# bind a row to named parameters
function bind{V}(stmt::SQLiteStmt, values::Dict{Symbol, V})
    nparams = sqlite3_bind_parameter_count(stmt.handle)
    @assert nparams == length(values) "you must provide values for all placeholders"
    for i in 1:nparams
        name = bytestring(sqlite3_bind_parameter_name(stmt.handle, i))
        @assert !isempty(name) "nameless parameters should be passed as a Vector"
        # name is returned with the ':', '@' or '$' at the start
        name = name[2:end]
        bind(stmt, i, values[symbol(name)])
    end
end
# Binding parameters to SQL statements
function bind(stmt::SQLiteStmt,name::AbstractString,val)
    i = sqlite3_bind_parameter_index(stmt.handle,name)
    if i == 0
        throw(SQLiteException("SQL parameter $name not found in $stmt"))
    end
    return bind(stmt,i,val)
end
bind(stmt::SQLiteStmt,i::Int,val::FloatingPoint)  = @CHECK stmt.db sqlite3_bind_double(stmt.handle,i,@compat Float64(val))
bind(stmt::SQLiteStmt,i::Int,val::Int32)          = @CHECK stmt.db sqlite3_bind_int(stmt.handle,i,val)
bind(stmt::SQLiteStmt,i::Int,val::Int64)          = @CHECK stmt.db sqlite3_bind_int64(stmt.handle,i,val)
bind(stmt::SQLiteStmt,i::Int,val::NullType)       = @CHECK stmt.db sqlite3_bind_null(stmt.handle,i)
bind(stmt::SQLiteStmt,i::Int,val::AbstractString) = @CHECK stmt.db sqlite3_bind_text(stmt.handle,i,val)
bind(stmt::SQLiteStmt,i::Int,val::UTF16String)    = @CHECK stmt.db sqlite3_bind_text16(stmt.handle,i,val)
# We may want to track the new ByteVec type proposed at https://github.com/JuliaLang/julia/pull/8964
# as the "official" bytes type instead of Vector{UInt8}
bind(stmt::SQLiteStmt,i::Int,val::Vector{UInt8})  = @CHECK stmt.db sqlite3_bind_blob(stmt.handle,i,val)
# Fallback is BLOB and defaults to serializing the julia value
function sqlserialize(x)
    t = IOBuffer()
    # deserialize will sometimes return a random object when called on an array
    # which has not been previously serialized, we can use this type to check
    # that the array has been serialized
    s = Serialization(x)
    serialize(t,s)
    return takebuf_array(t)
end
bind(stmt::SQLiteStmt,i::Int,val) = bind(stmt,i,sqlserialize(val))
#TODO:
#int sqlite3_bind_zeroblob(sqlite3_stmt*, int, int n);
#int sqlite3_bind_value(sqlite3_stmt*, int, const sqlite3_value*);

# Execute SQL statements
function execute(stmt::SQLiteStmt)
    r = sqlite3_step(stmt.handle)
    if r == SQLITE_DONE
        sqlite3_reset(stmt.handle)
    elseif r != SQLITE_ROW
        sqliteerror(stmt.db)
    end
    return r
end
function execute(db::SQLiteDB,sql::AbstractString)
    stmt = SQLiteStmt(db,sql)
    execute(stmt)
    return changes(db)
end

const SERIALIZATION = UInt8[0x11,0x01,0x02,0x0d,0x53,0x65,0x72,0x69,0x61,0x6c,0x69,0x7a,0x61,0x74,0x69,0x6f,0x6e,0x23]
function sqldeserialize(r)
    ret = ccall(:memcmp, Int32, (Ptr{UInt8},Ptr{UInt8}, UInt),
    SERIALIZATION, r, min(18,length(r)))

    if ret == 0
        v = deserialize(IOBuffer(r))
        return v.object
    else
        return r
    end
end

function query(db::SQLiteDB,sql::AbstractString, values=[])
    stmt = SQLiteStmt(db,sql)
    bind(stmt, values)
    status = execute(stmt)
    ncols = sqlite3_column_count(stmt.handle)
    if status == SQLITE_DONE || ncols == 0
        return changes(db)
    end
    colnames = Array(AbstractString,ncols)
    results = Array(Any,ncols)
    for i = 1:ncols
        colnames[i] = bytestring(sqlite3_column_name(stmt.handle,i-1))
        t = sqlite3_column_type(stmt.handle,i-1) 
        if t == SQLITE_INTEGER
            results[i] = Int64[]
        elseif t == SQLITE_FLOAT
            results[i] = Float64[]
        elseif t == SQLITE_TEXT
            results[i] = String[]
        else
            results[i] = Any[]
        end
    end
    
    while status == SQLITE_ROW
        for i = 1:ncols
            t = sqlite3_column_type(stmt.handle,i-1) 
            if t == SQLITE_INTEGER
                r = sqlite3_column_int64(stmt.handle,i-1)
            elseif t == SQLITE_FLOAT
                r = sqlite3_column_double(stmt.handle,i-1)
            elseif t == SQLITE_TEXT
                #TODO: have a way to return text16?
                r = bytestring( sqlite3_column_text(stmt.handle,i-1) )
            elseif t == SQLITE_BLOB
                blob = sqlite3_column_blob(stmt.handle,i-1)
                b = sqlite3_column_bytes(stmt.handle,i-1)
                buf = zeros(UInt8,b)
                unsafe_copy!(pointer(buf), convert(Ptr{UInt8},blob), b)
                r = sqldeserialize(buf)
            else
                r = NULL
            end
            push!(results[i],r)
        end
        status = sqlite3_step(stmt.handle)
    end
    if status == SQLITE_DONE
        return ResultSet(colnames, results)
    else
        sqliteerror(stmt.db)
    end
end

function tables(db::SQLiteDB)
    query(db,"SELECT name FROM sqlite_master WHERE type='table';")
end

function indices(db::SQLiteDB)
    query(db,"SELECT name FROM sqlite_master WHERE type='index';")
end

columns(db::SQLiteDB,table::String) = query(db,"pragma table_info($table)")

# Transaction-based commands
function transaction(db, mode="DEFERRED")
    #=
    Begin a transaction in the spedified mode, default "DEFERRED".

    If mode is one of "", "DEFERRED", "IMMEDIATE" or "EXCLUSIVE" then a
    transaction of that (or the default) type is started. Otherwise a savepoint
        is created whose name is mode converted to AbstractString.
        =#
        if uppercase(mode) in ["", "DEFERRED", "IMMEDIATE", "EXCLUSIVE"]
            execute(db, "BEGIN $(mode) TRANSACTION;")
        else
            execute(db, "SAVEPOINT $(mode);")
        end
    end

    function transaction(f::Function, db)
        #=
        Execute the function f within a transaction.
            =#
            # generate a random name for the savepoint
            name = string("SQLITE",randstring(10))
            execute(db,"PRAGMA synchronous = OFF")
            transaction(db, name)
            try
                f()
            catch
                rollback(db, name)
                rethrow()
            finally
                # savepoints are not released on rollback
                commit(db, name)
                execute(db,"PRAGMA synchronous = ON")
            end
        end

        # commit a transaction or savepoint (if name is given)
        commit(db) = execute(db, "COMMIT TRANSACTION;")
        commit(db, name) = execute(db, "RELEASE SAVEPOINT $(name);")

        # rollback transaction or savepoint (if name is given)
        rollback(db) = execute(db, "ROLLBACK TRANSACTION;")
        rollback(db, name) = execute(db, "ROLLBACK TRANSACTION TO SAVEPOINT $(name);")

        function droptable(db::SQLiteDB,table::AbstractString;ifexists::Bool=false)
            exists = ifexists ? "if exists" : ""
            transaction(db) do
            execute(db,"drop table $exists $table")
            end
            execute(db,"vacuum")
            return changes(db)
            end

            function dropindex(db::SQLiteDB,index::AbstractString;ifexists::Bool=false)
            exists = ifexists ? "if exists" : ""
            transaction(db) do
                execute(db,"drop index $exists $index")
            end
            return changes(db)
        end

        gettype{T<:Integer}(::Type{T}) = " INT"
        gettype{T<:Real}(::Type{T}) = " REAL"
        gettype{T<:AbstractString}(::Type{T}) = " TEXT"
        gettype(::Type) = " BLOB"
        gettype(::Type{NullType}) = " NULL"

        function create(db::SQLiteDB,name::AbstractString,table,
            colnames=AbstractString[],
            coltypes=DataType[]
            ;temp::Bool=false,ifnotexists::Bool=false)
            N, M = size(table)
            colnames = isempty(colnames) ? ["x$i" for i=1:M] : colnames
            coltypes = isempty(coltypes) ? [typeof(table[1,i]) for i=1:M] : coltypes
            length(colnames) == length(coltypes) || throw(SQLiteException("colnames and coltypes must have same length"))
            cols = [colnames[i] * gettype(coltypes[i]) for i = 1:M]
            transaction(db) do
                # create table statement
                t = temp ? "TEMP " : ""
                exists = ifnotexists ? "if not exists" : ""
                execute(db,"CREATE $(t)TABLE $exists $name ($(join(cols,',')))")
                # insert statements
                params = chop(repeat("?,",M))
                stmt = SQLiteStmt(db,"insert into $name values ($params)")
                #bind, step, reset loop for inserting values
                for row = 1:N
                for col = 1:M
                @inbounds v = table[row,col]
                bind(stmt,col,v)
                end
                execute(stmt)
                end
                end
                execute(db,"analyze $name")
                return changes(db)
                end

                function createindex(db::SQLiteDB,table::AbstractString,index::AbstractString,cols
                ;unique::Bool=true,ifnotexists::Bool=false)
                u = unique ? "unique" : ""
                exists = ifnotexists ? "if not exists" : ""
                transaction(db) do
                    execute(db,"create $u index $exists $index on $table ($cols)")
                end
                execute(db,"analyze $index")
                return changes(db)
            end

            function append(db::SQLiteDB,name::AbstractString,table)
                N, M = size(table)
                transaction(db) do
                    # insert statements
                    params = chop(repeat("?,",M))
                    stmt = SQLiteStmt(db,"insert into $name values ($params)")
                    #bind, step, reset loop for inserting values
                    for row = 1:N
                        for col = 1:M
                            @inbounds v = table[row,col]
                            bind(stmt,col,v)
                        end
                        execute(stmt)
                    end
                end
                execute(db,"analyze $name")
                return return changes(db)
            end

            function deleteduplicates(db,table::AbstractString,cols::AbstractString)
                transaction(db) do
                    execute(db,"delete from $table where rowid not in (select max(rowid) from $table group by $cols);")
                end
                execute(db,"analyze $table")
                return changes(db)
            end

        end #SQLite module
