#ifndef CTDLIBSQLITE_H
#define CTDLIBSQLITE_H

// Declarations for the SQLite (SQLCipher) build that TDLib bundles under the
// `tdsqlite3_` prefix. The definitions live in the TDLibFramework static
// archive, which TelegramAllLib already links; this header only lets Swift call
// them with the C calling convention. Used by the read-only local reader
// (PsychQuant/che-msg#58).

typedef struct tdsqlite3 tdsqlite3;
typedef struct tdsqlite3_stmt tdsqlite3_stmt;

#define TDSQLITE_OK 0
#define TDSQLITE_ROW 100
#define TDSQLITE_DONE 101
#define TDSQLITE_NULL 5
#define TDSQLITE_OPEN_READONLY 0x00000001
#define TDSQLITE_OPEN_URI 0x00000040

int tdsqlite3_open_v2(const char *filename, tdsqlite3 **db, int flags, const char *vfs);
int tdsqlite3_close(tdsqlite3 *db);
int tdsqlite3_exec(tdsqlite3 *db, const char *sql, int (*callback)(void *, int, char **, char **), void *arg, char **errmsg);
int tdsqlite3_prepare_v2(tdsqlite3 *db, const char *sql, int nbyte, tdsqlite3_stmt **stmt, const char **tail);
int tdsqlite3_step(tdsqlite3_stmt *stmt);
int tdsqlite3_finalize(tdsqlite3_stmt *stmt);
int tdsqlite3_bind_int64(tdsqlite3_stmt *stmt, int index, long long value);
int tdsqlite3_bind_blob(tdsqlite3_stmt *stmt, int index, const void *value, int length, void (*destructor)(void *));
int tdsqlite3_column_count(tdsqlite3_stmt *stmt);
int tdsqlite3_column_type(tdsqlite3_stmt *stmt, int index);
long long tdsqlite3_column_int64(tdsqlite3_stmt *stmt, int index);
const unsigned char *tdsqlite3_column_text(tdsqlite3_stmt *stmt, int index);
const void *tdsqlite3_column_blob(tdsqlite3_stmt *stmt, int index);
int tdsqlite3_column_bytes(tdsqlite3_stmt *stmt, int index);
const char *tdsqlite3_errmsg(tdsqlite3 *db);

// Binds a private copy of `value` (SQLITE_TRANSIENT), so the caller's buffer
// may be released as soon as the call returns.
int ctdlib_bind_blob_copy(tdsqlite3_stmt *stmt, int index, const void *value, int length);

#endif
