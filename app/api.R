# The workshop api: the only service that reads the answer key and writes the state.
# Every request carries a token (Authorization: Bearer <token>); the api decides everything from it alone.
#
# Participants (their tutorial container holds their own token):
#   GET  /me              open sections, own saved answers, released feedback for those answers
#   POST /answer          {"id": "<question id>", "value": <number or string>}: validate, save; 403 if closed
# Facilitator (admin token, only in the facilitator app's container):
#   GET  /admin/overview  definition, key, releases, participants, all answers
#   POST /admin/release   {"keys": [...], "target": "*" | "<participant>", "on": true|false}
#   GET  /health          liveness (no token)
#
# Environment: WS_WORKSHOP (folder with questions.yml), WS_KEY (key.yml), WS_DB (SQLite state file).
# Answers are never logged.

source(file.path(Sys.getenv("WS_HOME", "/srv/workshop"), "app", "core.R"))

def <- ws_definition(file.path(Sys.getenv("WS_WORKSHOP"), "questions.yml"))
key <- ws_key(Sys.getenv("WS_KEY"), def)
con <- ws_db(Sys.getenv("WS_DB"))

body_of <- function(req) tryCatch(jsonlite::fromJSON(req$postBody, simplifyVector = TRUE), error = function(e) NULL)
reply <- function(res, out) { res$status <- out$status; out$status <- NULL; out }

#* @filter auth
function(req, res) {
  if (identical(req$PATH_INFO, "/health")) return(plumber::forward())
  token <- sub("^Bearer\\s+", "", req$HTTP_AUTHORIZATION %||% "")
  if (startsWith(req$PATH_INFO, "/admin/")) {
    if (!ws_is_admin(con, token)) { res$status <- 401L; return(list(error = "Admin token required.")) }
  } else {
    req$pid <- ws_participant_for(con, token)
    if (is.null(req$pid)) { res$status <- 401L; return(list(error = "Unknown token.")) }
  }
  plumber::forward()
}

#* @get /health
#* @serializer unboxedJSON
function() list(ok = TRUE)

#* @get /me
#* @serializer unboxedJSON list(na = "null")
function(req) ws_me(con, def, key, req$pid)

#* @post /answer
#* @serializer unboxedJSON
function(req, res) {
  b <- body_of(req)
  if (!is.list(b) || !is.character(b$id) || length(b$id) != 1) {
    return(reply(res, list(status = 400L, error = "Send {\"id\": ..., \"value\": ...}.")))
  }
  reply(res, ws_save_answer(con, def, req$pid, b$id, b$value))
}

#* @get /admin/overview
#* @serializer json list(auto_unbox = TRUE, na = "null", digits = NA)
function() {
  a <- ws_answers(con)
  pr <- ws_presence(con)
  list(definition = def, key = key, releases = ws_release_table(con), participants = ws_participants(con),
       presence = lapply(seq_len(nrow(pr)), function(i) list(id = pr$id[i], name = pr$name[i], last_seen = pr$last_seen[i], online = pr$online[i])),
       answers = lapply(seq_len(nrow(a)), function(i) list(participant = a$participant[i], question = a$question[i],
                                                           value = a$value[[i]], saved_at = a$saved_at[i])))
}

#* @post /admin/release
#* @serializer unboxedJSON
function(req, res) {
  b <- body_of(req)
  if (!is.list(b) || !is.character(b$target)) return(reply(res, list(status = 400L, error = "Send keys, target, on.")))
  reply(res, ws_release(con, def, key, b$keys, b$target, b$on))
}
