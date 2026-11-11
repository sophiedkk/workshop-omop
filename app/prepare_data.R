# Build the workshop's OMOP dataset once: download synthea-covid19-10k with omock and save it as one DuckDB
# file, run/data/synthea-covid19-10k.duckdb, that every participant's container attaches READ_ONLY.
#
#   ./ws prepare-data
#
# Needs ~13 GB RAM once (omock loads every table into memory). On a smaller machine, run it elsewhere and
# copy the .duckdb file into run/data/. Does nothing when the file is already there.

out_dir <- "/run-dir/data"
db <- file.path(out_dir, "synthea-covid19-10k.duckdb")
if (file.exists(db)) {
  message("Already there: run/data/synthea-covid19-10k.duckdb")
  quit(save = "no")
}
dir.create(file.path(out_dir, "download", "mockDatasets"), recursive = TRUE, showWarnings = FALSE)
Sys.setenv(OMOP_DATA_FOLDER = file.path(out_dir, "download"))
options(timeout = 1800)
omock::downloadMockDataset(datasetName = "synthea-covid19-10k", overwrite = FALSE)
cdm <- omock::mockCdmFromDataset(datasetName = "synthea-covid19-10k", source = "duckdb")
con <- CDMConnector::cdmCon(cdm)
src <- DBI::dbGetQuery(con, "SELECT path FROM duckdb_databases() WHERE NOT internal")$path[1]
DBI::dbExecute(con, "DROP SCHEMA IF EXISTS results CASCADE")   # participants get their own
DBI::dbExecute(con, "CHECKPOINT")
DBI::dbDisconnect(con, shutdown = TRUE)
stopifnot(file.copy(src, paste0(db, ".part")), file.rename(paste0(db, ".part"), db))
Sys.chmod(db, "444")
unlink(file.path(out_dir, "download"), recursive = TRUE)
message("Built run/data/synthea-covid19-10k.duckdb (", round(file.size(db) / 1e9, 2), " GB)")
