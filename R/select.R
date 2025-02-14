#' Select records
#'
#' @param conn A DBIConnection object
#' @param statement The SQL statement to use
#' @param params Parameters to bind
#' @export
#' @examples
#' db <- dbxConnect(adapter="sqlite", dbname=":memory:")
#' DBI::dbCreateTable(db, "forecasts", data.frame(id=1:3, temperature=20:22))
#'
#' dbxSelect(db, "SELECT * FROM forecasts")
#'
#' dbxSelect(db, "SELECT * FROM forecasts WHERE id = ?", params=list(1))
#'
#' dbxSelect(db, "SELECT * FROM forecasts WHERE id IN (?)", params=list(1:3))
dbxSelect <- function(conn, statement, params=NULL) {
  statement <- processStatement(statement)
  cast_dates <- list()
  cast_datetimes <- list()
  convert_tz <- list()
  cast_booleans <- list()
  stringify_json <- list()
  unescape_blobs <- list()
  fix_timetz <- list()
  change_tz <- list()

  r <- fetchRecords(conn, statement, params)
  records <- r$records
  column_info <- r$column_info

  # typecasting
  if (isRPostgreSQL(conn)) {
    sql_types <- tolower(column_info$type)

    if (storageTimeZone(conn) != currentTimeZone()) {
      convert_tz <- which(sql_types == "timestamp")
    }

    unescape_blobs <- which(sql_types == "bytea")
    fix_timetz <- which(sql_types == "timetzoid")
  } else if (isRPostgres(conn)) {
    sql_types <- column_info$`.typname`

    if (storageTimeZone(conn) != currentTimeZone() && utils::packageVersion("RPostgres") < "1.3.0") {
      convert_tz <- which(sql_types == "timestamp")
    }

    stringify_json <- which(sql_types %in% c("json", "jsonb"))
  } else if (isRMySQL(conn)) {
    sql_types <- tolower(column_info$type)

    cast_dates <- which(sql_types == "date")
    cast_datetimes <- which(sql_types %in% c("datetime", "timestamp"))
    cast_booleans <- which(sql_types == "tinyint" & column_info$length == 1)
  } else if (isRMariaDB(conn)) {
    # TODO cast booleans for RMariaDB
    # waiting on https://github.com/r-dbi/RMariaDB/issues/100
  } else if (isSQLite(conn)) {
    # TODO cast dates and times for RSQLite
    # waiting on https://github.com/r-dbi/RSQLite/issues/263
  } else if (isODBC(conn)) {
    # TODO cast booleans for Postgres ODBC
    # https://github.com/r-dbi/odbc/issues/108
    # booleans currently returned as VARCHAR
    # print(column_info)
    sql_types <- column_info$type
    change_tz <- which(sql_types == 93)
    cast_booleans <- which(sql_types == -6)
  }

  # fix for empty data frame
  if (isRPostgreSQL(conn) && (ncol(records) == 0 || nrow(records) == 0)) {
    for (i in 1:nrow(column_info)) {
      row <- column_info[i, ]
      records[, i] <- emptyType(row$Sclass)
    }
    colnames(records) <- column_info$name

    for (i in unescape_blobs) {
      records[[colnames(records)[i]]] <- list()
    }
  }

  for (i in cast_booleans) {
    records[, i] <- records[, i] != 0
  }

  for (i in stringify_json) {
    records[, i] <- as.character(records[, i])
  }

  for (i in change_tz) {
    attr(records[, i], "tzone") <- currentTimeZone()
  }

  if (nrow(records) > 0) {
    for (i in cast_dates) {
      records[, i] <- as.Date(records[, i])
    }

    for (i in cast_datetimes) {
      records[, i] <- as.POSIXct(records[, i], tz=storageTimeZone(conn))
      attr(records[, i], "tzone") <- currentTimeZone()
    }

    for (i in convert_tz) {
      records[, i] <- as.POSIXct(format(records[, i], "%Y-%m-%d %H:%M:%OS6"), tz=storageTimeZone(conn))
      attr(records[, i], "tzone") <- currentTimeZone()
    }

    for (i in unescape_blobs) {
      records[[colnames(records)[i]]] <- lapply(records[, i], function(x) { if (is.na(x)) NULL else RPostgreSQL::postgresqlUnescapeBytea(x) })
    }

    for (i in fix_timetz) {
      records[, i] <- gsub("\\+00$", "", records[, i])
    }

    uncast_times <- which(sapply(records, isTime))
    for (i in uncast_times) {
      records[, i] <- as.character(records[, i])
    }

    uncast_blobs <- which(sapply(records, isBlob))
    for (i in uncast_blobs) {
      col <- lapply(records[, i], as.raw)
      null_vector <- as.raw(NULL)
      col <- lapply(col, function(x) { if (identical(x, null_vector)) NULL else x })
      records[[colnames(records)[i]]] <- col
    }
  } else {
    for (i in cast_dates) {
      records[, i] <- as.Date(as.character())
    }

    for (i in cast_datetimes) {
      records[, i] <- as.POSIXct(as.character())
    }

    uncast_times <- which(sapply(records, isTime))
    for (i in uncast_times) {
      records[, i] <- as.character()
    }

    uncast_blobs <- which(sapply(records, isBlob))
    for (i in uncast_blobs) {
      records[[colnames(records)[i]]] <- list()
    }
  }

  records
}

fetchRecords <- function(conn, statement, params) {
  ret <- list()
  column_info <- NULL

  silenceWarnings(c("length of NULL cannot be changed", "unrecognized MySQL field type", "unrecognized PostgreSQL field type", "(unknown (", "Decimal MySQL column"), {
    statement <- addParams(conn, statement, params)

    res <- NULL
    timeStatement(statement, {
      res <- DBI::dbSendQuery(conn, statement)
    })

    # always fetch at least once
    ret[[length(ret) + 1]] <- DBI::dbFetch(res)

    # must come after first fetch call for SQLite
    column_info <- DBI::dbColumnInfo(res)

    while (!DBI::dbHasCompleted(res)) {
      ret[[length(ret) + 1]] <- DBI::dbFetch(res)
    }
    DBI::dbClearResult(res)
  })

  list(records=combineResults(ret), column_info=column_info)
}

emptyType <- function(type) {
  if (identical(type, "Date")) {
    as.Date(as.character())
  } else if (identical(type, "POSIXct")) {
    as.POSIXct(as.character())
  } else if (identical(type, "integer")) {
    as.integer()
  } else if (identical(type, "numeric")) {
    as.numeric()
  } else if (identical(type, "double")) {
    as.double()
  } else if (identical(type, "logical")) {
    as.logical()
  } else {
    as.character()
  }
}

silenceWarnings <- function(msgs, code) {
  warn <- function(w) {
    if (any(sapply(msgs, function(x) { grepl(x, conditionMessage(w), fixed=TRUE) }))) {
      invokeRestart("muffleWarning")
    }
  }
  withCallingHandlers(code, warning=warn)
}
