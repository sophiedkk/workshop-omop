# Core of the workshop: the definition (questions.yml), the key (key.yml), the state (SQLite) and the rules.
# Used by the api (participants) and the facilitator app (trusted side). The tutorial does not use this file:
# it only talks to the api.
#
# Release keys: "open:<section id>" opens a gated section, "feedback:<question id>" shows that question's
# feedback, "notices:off" stops the pop-up notices on participants' pages ("... is now open", "Feedback is
# ready"). A release targets one participant id or "*" (everyone).

ALL <- "*"
NOTICES_OFF <- "notices:off"
TEXT_LIMIT <- 5000L
QUESTION_TYPES <- c("number", "choice", "text")
ID_PATTERN <- "^[A-Za-z0-9][A-Za-z0-9_-]*$"

# ---------------------------------------------------------------- definition and key

#' Load and check a workshop definition (questions.yml). Stops with every problem listed.
ws_definition <- function(path) {
  d <- yaml::read_yaml(path)
  problems <- character()
  sections <- d$sections %||% list()
  questions <- d$questions %||% list()
  sids <- vapply(sections, function(s) s$id %||% "", "")
  qids <- vapply(questions, function(q) q$id %||% "", "")
  for (s in sections) {
    if (!grepl(ID_PATTERN, s$id %||% "")) problems <- c(problems, sprintf("section id '%s' is not valid", s$id %||% ""))
    if (!nzchar(s$title %||% "")) problems <- c(problems, sprintf("section '%s' has no title", s$id))
  }
  if (anyDuplicated(sids)) problems <- c(problems, paste("duplicate section ids:", toString(unique(sids[duplicated(sids)]))))
  if (anyDuplicated(qids)) problems <- c(problems, paste("duplicate question ids:", toString(unique(qids[duplicated(qids)]))))
  for (q in questions) {
    where <- sprintf("question '%s'", q$id %||% "")
    if (!grepl(ID_PATTERN, q$id %||% "")) problems <- c(problems, paste(where, "has no valid id"))
    if (!(q$section %||% "") %in% sids) problems <- c(problems, paste(where, "is in unknown section", q$section %||% "(none)"))
    if (!(q$type %||% "") %in% QUESTION_TYPES) problems <- c(problems, paste(where, "has unknown type", q$type %||% "(none)"))
    if (!nzchar(q$prompt %||% "")) problems <- c(problems, paste(where, "has no prompt"))
    if (identical(q$type, "choice")) {
      opts <- unlist(q$options)
      if (length(opts) < 2) problems <- c(problems, paste(where, "needs at least two options"))
      if (anyDuplicated(opts)) problems <- c(problems, paste(where, "has duplicate options"))
    }
  }
  if (length(problems)) stop("Problems in ", path, ":\n  ", paste(problems, collapse = "\n  "), call. = FALSE)
  for (i in seq_along(sections)) sections[[i]]$gated <- !isFALSE(sections[[i]]$gated)  # gated unless false
  names(sections) <- sids
  names(questions) <- qids
  list(title = d$title %||% "Workshop", sections = sections, questions = questions)
}

#' Load the key and check it against the definition. Stops with every problem listed.
ws_key <- function(path, def) {
  key <- yaml::read_yaml(path) %||% list()
  problems <- character()
  for (id in names(key)) {
    q <- def$questions[[id]]
    k <- key[[id]]
    if (is.null(q)) { problems <- c(problems, sprintf("key has '%s', which is not a question", id)); next }
    if (q$type == "number") {
      if (!is.numeric(k$expected)) problems <- c(problems, sprintf("'%s': number needs 'expected'", id))
    } else if (q$type == "choice") {
      opts <- unlist(q$options)
      if (!setequal(names(k$options), opts)) {
        problems <- c(problems, sprintf("'%s': key options (%s) differ from the question's (%s)", id,
                                        toString(names(k$options)), toString(opts)))
      }
      verdicts <- vapply(k$options, function(v) v[[1]], "")
      if (!all(verdicts %in% c("right", "wrong", "info"))) problems <- c(problems, sprintf("'%s': verdicts must be right, wrong or info", id))
    } else {
      problems <- c(problems, sprintf("'%s': %s questions have no key", id, q$type))
    }
  }
  if (length(problems)) stop("Problems in ", path, ":\n  ", paste(problems, collapse = "\n  "), call. = FALSE)
  key
}

ws_has_feedback <- function(key, qid) !is.null(key[[qid]])
ws_section_questions <- function(def, sid) Filter(function(q) q$section == sid, def$questions)

# ---------------------------------------------------------------- state

#' Open (and create if needed) the state database.
ws_db <- function(path) {
  con <- DBI::dbConnect(RSQLite::SQLite(), path)
  DBI::dbExecute(con, "PRAGMA journal_mode = WAL")
  DBI::dbExecute(con, "PRAGMA busy_timeout = 5000")
  DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS participants (id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE)")
  DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS admins (token_hash TEXT PRIMARY KEY)")
  # last_seen: when the participant's page last asked for its state (every few seconds while it is open).
  if (!"last_seen" %in% DBI::dbListFields(con, "participants")) {
    DBI::dbExecute(con, "ALTER TABLE participants ADD COLUMN last_seen TEXT")
  }
  # name: the participant's full name, for the facilitator page and the login cards (the id is the username).
  if (!"name" %in% DBI::dbListFields(con, "participants")) {
    DBI::dbExecute(con, "ALTER TABLE participants ADD COLUMN name TEXT")
  }
  DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS releases (key TEXT NOT NULL, target TEXT NOT NULL, PRIMARY KEY (key, target))")
  DBI::dbExecute(con, paste("CREATE TABLE IF NOT EXISTS answers (participant TEXT NOT NULL, question TEXT NOT NULL,",
                            "value TEXT NOT NULL, saved_at TEXT NOT NULL, PRIMARY KEY (participant, question))"))
  con
}

ws_hash <- function(token) as.character(openssl::sha256(token))

ws_add_participant <- function(con, id, token, name = id) {
  if (!grepl(ID_PATTERN, id)) stop("participant id '", id, "' is not valid", call. = FALSE)
  DBI::dbExecute(con, "INSERT INTO participants (id, token_hash, name) VALUES (?, ?, ?)", params = list(id, ws_hash(token), name))
}

ws_participants <- function(con) DBI::dbGetQuery(con, "SELECT id FROM participants ORDER BY id")$id

ONLINE_SECONDS <- 30
ws_now <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
ws_seen <- function(con, pid) DBI::dbExecute(con, "UPDATE participants SET last_seen = ? WHERE id = ?", params = list(ws_now(), pid))

#' Participants with their last contact and whether their page is open now (seen in the last ONLINE_SECONDS).
ws_presence <- function(con) {
  d <- DBI::dbGetQuery(con, "SELECT id, COALESCE(name, id) AS name, last_seen FROM participants ORDER BY id")
  seen <- as.POSIXct(d$last_seen, format = "%Y-%m-%dT%H:%M:%S%z")
  d$online <- !is.na(seen) & as.numeric(difftime(Sys.time(), seen, units = "secs")) <= ONLINE_SECONDS
  d
}

#' The participant a token belongs to, or NULL.
ws_participant_for <- function(con, token) {
  if (!is.character(token) || length(token) != 1 || !nzchar(token)) return(NULL)
  id <- DBI::dbGetQuery(con, "SELECT id FROM participants WHERE token_hash = ?", params = list(ws_hash(token)))$id
  if (length(id) == 1) id else NULL
}

ws_add_admin <- function(con, token) {
  DBI::dbExecute(con, "INSERT INTO admins (token_hash) VALUES (?)", params = list(ws_hash(token)))
}

ws_is_admin <- function(con, token) {
  is.character(token) && length(token) == 1 && nzchar(token) &&
    nrow(DBI::dbGetQuery(con, "SELECT 1 FROM admins WHERE token_hash = ?", params = list(ws_hash(token)))) == 1
}

#' Every release key the facilitator may set: open:<gated section>, feedback:<question with a key entry>, and
#' notices:off.
ws_release_keys <- function(def, key) {
  opens <- paste0("open:", names(Filter(function(s) isTRUE(s$gated), def$sections)))
  c(opens, paste0("feedback:", intersect(names(def$questions), names(key))), NOTICES_OFF)
}

#' Set releases from the facilitator: only known keys, and a target that is "*" or a participant.
ws_release <- function(con, def, key, keys, target, on) {
  keys <- unlist(keys)
  if (!length(keys) || !all(keys %in% ws_release_keys(def, key))) return(list(status = 400L, error = "Unknown release key."))
  if (!(identical(target, ALL) || target %in% ws_participants(con))) return(list(status = 400L, error = "Unknown participant."))
  ws_set_release(con, keys, target, isTRUE(on))
  list(status = 200L, saved = TRUE)
}

ws_set_release <- function(con, keys, target, on) {
  for (k in keys) {
    if (on) DBI::dbExecute(con, "INSERT OR IGNORE INTO releases (key, target) VALUES (?, ?)", params = list(k, target))
    else DBI::dbExecute(con, "DELETE FROM releases WHERE key = ? AND target = ?", params = list(k, target))
  }
  invisible(TRUE)
}

ws_release_table <- function(con) DBI::dbGetQuery(con, "SELECT key, target FROM releases")

#' Release keys that apply to a participant (released to them or to everyone).
ws_released <- function(con, pid) {
  DBI::dbGetQuery(con, "SELECT DISTINCT key FROM releases WHERE target = ? OR target = ?", params = list(pid, ALL))$key
}

ws_is_open <- function(def, released, sid) !isTRUE(def$sections[[sid]]$gated) || paste0("open:", sid) %in% released

# ---------------------------------------------------------------- answers

#' Check a value for a question. Returns list(value = normalised value) or list(error = message).
ws_check_value <- function(q, value) {
  if (q$type == "number") {
    if (!is.numeric(value) || length(value) != 1 || !is.finite(value)) return(list(error = "Fill in a number."))
    return(list(value = as.numeric(value)))
  }
  if (!is.character(value) || length(value) != 1 || is.na(value)) return(list(error = "Give one answer."))
  if (q$type == "choice") {
    if (!value %in% unlist(q$options)) return(list(error = "Choose one of the options."))
    return(list(value = value))
  }
  value <- trimws(value)
  if (!nzchar(value)) return(list(error = "Fill in an answer first."))
  if (nchar(value) > TEXT_LIMIT) return(list(error = sprintf("Your answer is too long (at most %d characters).", TEXT_LIMIT)))
  list(value = value)
}

#' Save a participant's answer. Returns list(status = HTTP status, saved or error).
ws_save_answer <- function(con, def, pid, qid, value) {
  q <- def$questions[[qid]]
  if (is.null(q)) return(list(status = 404L, error = "Unknown question."))
  if (!ws_is_open(def, ws_released(con, pid), q$section)) {
    return(list(status = 403L, error = "This part is not open yet. Wait until your facilitator opens it."))
  }
  checked <- ws_check_value(q, value)
  if (!is.null(checked$error)) return(list(status = 400L, error = checked$error))
  DBI::dbExecute(con, paste("INSERT INTO answers (participant, question, value, saved_at) VALUES (?, ?, ?, ?)",
                            "ON CONFLICT (participant, question) DO UPDATE SET value = excluded.value, saved_at = excluded.saved_at"),
                 params = list(pid, qid, jsonlite::toJSON(checked$value, auto_unbox = TRUE, digits = NA), ws_now()))
  list(status = 200L, saved = TRUE)
}

#' All answers, or one participant's: a data frame participant, question, value (parsed), saved_at.
ws_answers <- function(con, pid = NULL) {
  df <- if (is.null(pid)) DBI::dbGetQuery(con, "SELECT * FROM answers")
        else DBI::dbGetQuery(con, "SELECT * FROM answers WHERE participant = ?", params = list(pid))
  df$value <- lapply(df$value, jsonlite::fromJSON)
  df
}

# ---------------------------------------------------------------- feedback

#' Feedback for a saved value: list(ok = TRUE/FALSE/NA, text). NULL if the question has none.
ws_judge <- function(key, q, value) {
  k <- key[[q$id]]
  if (is.null(k)) return(NULL)
  if (q$type == "number") {
    ok <- is.numeric(value) && abs(value - k$expected) <= (k$tolerance %||% 0)
    return(list(ok = ok, text = if (ok) k$ok %||% "" else k$bad %||% "Not quite.", explain = k$explain %||% ""))
  }
  v <- k$options[[value]]
  if (is.null(v)) return(NULL)
  list(ok = switch(v[[1]], right = TRUE, wrong = FALSE, NA), text = v[[2]] %||% "", explain = k$explain %||% "")
}

#' What the participant's screen needs: open sections, their saved answers, released feedback, and whether to
#' show pop-up notices. Released
#' feedback also reaches participants who did not answer ("not answered" plus the explanation), so nobody
#' is left without it. Only ever this participant's data; never key content that is not released.
ws_me <- function(con, def, key, pid) {
  ws_seen(con, pid)
  released <- ws_released(con, pid)
  answers <- ws_answers(con, pid)
  saved <- stats::setNames(answers$value, answers$question)
  open <- names(Filter(function(s) ws_is_open(def, released, s$id), def$sections))
  feedback <- list()
  for (qid in intersect(names(def$questions), names(key))) {
    if (!paste0("feedback:", qid) %in% released) next
    fb <- if (qid %in% names(saved)) ws_judge(key, def$questions[[qid]], saved[[qid]])
          else list(ok = NA, unanswered = TRUE, text = "You did not save an answer to this question.",
                    explain = key[[qid]]$explain %||% "")
    if (!is.null(fb)) feedback[[qid]] <- fb
  }
  list(participant = pid, open = as.list(open), answers = saved, feedback = feedback,
       notices = !NOTICES_OFF %in% released)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
