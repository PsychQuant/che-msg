#include "CTDLibSQLite.h"

int ctdlib_bind_blob_copy(tdsqlite3_stmt *stmt, int index, const void *value, int length) {
  return tdsqlite3_bind_blob(stmt, index, value, length, (void (*)(void *))-1);
}
