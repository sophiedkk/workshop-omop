# Tutorial side of the workshop (learnr). The tutorial never sees the key: it only talks to the api with the
# participant's own token.
#
# In tutorial.Rmd:
#   ws_assets()             once, near the top (look and feel, Hanze colours, sidebar status, notices)
#   ::: {.ws-section data-section="people"}  ... :::   wraps a gated part's content (hidden until opened)
#   ws_question("n_people") a question, rendered from questions.yml (starts empty)
#   ws_server(session)      once, in a context="server" chunk: follows the facilitator live
#
# Participants are not technical: every text on the page is plain language, there is one obvious action per
# step, and nothing on the page can lose their work (learnr's "Start Over" for the whole tutorial is removed).
#
# Environment: WS_API (default http://api:8000), WS_TOKEN_FILE (default /run/ws/token).

WS_POLL_MS <- 3000
.ws_cache <- new.env()

# ---------------------------------------------------------------- the data
# The dataset is one DuckDB file that everyone shares, attached read-only as "omop". Tables a participant creates
# (compute(), OmopSketch) go to their own in-memory database, schema "results".

#' Connect to the shared data and return the cdm reference.
ws_cdm <- function() {
  shared <- Sys.getenv("WS_DATA", "/data/synthea-covid19-10k.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
  invisible(DBI::dbExecute(con, "SET memory_limit = '1GB'"))   # DuckDB would otherwise size to the whole server
  invisible(DBI::dbExecute(con, "SET threads = 2"))
  invisible(DBI::dbExecute(con, sprintf("ATTACH '%s' AS omop (READ_ONLY)", shared)))
  invisible(DBI::dbExecute(con, "CREATE SCHEMA results"))
  cdm <- CDMConnector::cdmFromCon(con, cdmSchema = c(catalog = "omop", schema = "main"),
                                  writeSchema = "results", cdmName = "synthea-covid19-10k")
  .ws_cache$cdm <- cdm
  cdm
}

#' Run before every code box. Each box starts from a fresh copy of `cdm`, so `cdm <- 5` in one box does not reach
#' the next. But the database connection is shared: if a participant closed it (cdmDisconnect(cdm)), reconnect.
ws_cdm_ok <- function(cdm) {
  ok <- function(x) inherits(x, "cdm_reference") &&
    isTRUE(tryCatch(DBI::dbIsValid(CDMConnector::cdmCon(x)), error = function(e) FALSE))
  if (ok(cdm)) return(cdm)
  if (ok(.ws_cache$cdm)) return(.ws_cache$cdm)
  ws_cdm()
}

.ws_questions <- function() {
  if (is.null(.ws_cache$def)) .ws_cache$def <- yaml::read_yaml("questions.yml")
  .ws_cache$def
}

#' How results that are tables show in code boxes (learnr's exercise.df_print; set in the tutorial's setup chunk).
#' One plain table with every column, in a box that scrolls with the mouse wheel or trackpad, instead of learnr's
#' paged table with its buttons. A database table (lazy) is read up to `max_rows` rows; so is a data frame.
ws_print_table <- function(x, max_rows = 1000) {
  rows <- if (inherits(x, "tbl_lazy")) dplyr::collect(utils::head(x, max_rows + 1)) else utils::head(x, max_rows + 1)
  rows <- as.data.frame(rows, stringsAsFactors = FALSE)
  more <- nrow(rows) > max_rows
  rows <- utils::head(rows, max_rows)
  esc <- htmltools::htmlEscape
  type <- function(v) if (inherits(v, "POSIXct")) "dttm" else if (inherits(v, "Date")) "date" else if (is.integer(v)) "int"
                      else if (is.numeric(v)) "dbl" else if (is.logical(v)) "lgl" else if (is.list(v)) "list" else "chr"
  cell <- function(v) {
    txt <- if (is.list(v)) vapply(v, function(e) toString(e), "")
           else if (is.numeric(v)) format(v, trim = TRUE, scientific = FALSE, digits = 7, big.mark = "")
           else as.character(v)
    na <- if (is.list(v)) rep(FALSE, length(v)) else is.na(v)
    txt[na] <- "NA"
    list(txt = esc(txt), na = na)
  }
  num <- vapply(rows, is.numeric, TRUE)
  cols <- lapply(rows, cell)
  head <- paste0(sprintf('<th%s>%s<small>&lt;%s&gt;</small></th>', ifelse(num, ' class="ws-num"', ""),
                         esc(names(rows)), vapply(rows, type, "")), collapse = "")
  body <- vapply(seq_len(nrow(rows)), function(i) paste0("<tr>", paste0(vapply(seq_along(cols), function(j) {
    cls <- c(if (num[j]) "ws-num", if (cols[[j]]$na[i]) "ws-na")
    sprintf("<td%s>%s</td>", if (length(cls)) sprintf(' class="%s"', paste(cls, collapse = " ")) else "", cols[[j]]$txt[i])
  }, ""), collapse = ""), "</tr>"), "")
  n_txt <- function(n, what) sprintf("%s %s%s", format(n, big.mark = ","), what, if (n == 1) "" else "s")
  note <- if (more) sprintf("The first %s, %s. Scroll in the table to see everything.", n_txt(max_rows, "row"), n_txt(ncol(rows), "column"))
          else sprintf("%s, %s.", n_txt(nrow(rows), "row"), n_txt(ncol(rows), "column"))
  knitr::asis_output(paste0('<div class="ws-table"><table><thead><tr>', head, '</tr></thead><tbody>',
                            paste(body, collapse = ""), '</tbody></table></div><p class="ws-table-note">', note, "</p>"))
}

.ws_md <- function(text) htmltools::HTML(sub("^<p>(.*)</p>\n?$", "\\1", commonmark::markdown_html(text)))

#' A question card. Nothing is pre-filled or pre-selected.
ws_question <- function(id) {
  qs <- .ws_questions()$questions
  q <- Filter(function(x) identical(x$id, id), qs)
  if (length(q) != 1) stop("ws_question('", id, "'): not in questions.yml", call. = FALSE)
  q <- q[[1]]
  tags <- htmltools::tags
  input <- switch(q$type,
    number = tags$div(class = "ws-number",
                      tags$input(type = "number", class = "form-control ws-input", step = "any",
                                 `aria-label` = "Your answer", placeholder = "Your answer"),
                      if (!is.null(q$unit)) tags$span(class = "ws-unit", q$unit)),
    choice = tags$div(class = "ws-options", role = "radiogroup", lapply(unlist(q$options), function(o) {
      tags$label(class = "ws-option", tags$input(type = "radio", name = paste0("ws-", id), value = o), tags$span(o))
    })),
    text = tags$textarea(class = "form-control ws-input", rows = 3,
                         placeholder = "Type your answer here (Shift+Enter for a new line)",
                         `aria-label` = "Your answer")
  )
  tags$div(
    class = "ws-question", `data-id` = id, `data-type` = q$type,
    tags$div(class = "ws-question-label", "Question"),
    tags$p(class = "ws-prompt", .ws_md(q$prompt)),
    input,
    tags$div(class = "ws-actions",
      tags$button(type = "button", class = "ws-save", "Save answer"),
      tags$span(class = "ws-status", role = "status")),
    tags$div(class = "ws-feedback", role = "status")
  )
}

#' Look and feel, sidebar status and notices. Include once.
ws_assets <- function() {
  svg_uri <- function(name) {
    f <- file.path(Sys.getenv("WS_HOME", "/srv/workshop"), "branding", name)
    if (file.exists(f)) paste0("data:image/svg+xml;base64,", jsonlite::base64_enc(readBin(f, "raw", file.size(f)))) else ""
  }
  logo_uri <- svg_uri("hanze-logo.svg")
  payoff_uri <- svg_uri("hanze-payoff.svg")
  htmltools::tagList(
    htmltools::tags$style(htmltools::HTML(WS_CSS)),
    htmltools::tags$script(htmltools::HTML(sprintf("window.WS_LOGO = %s; window.WS_PAYOFF = %s;",
      jsonlite::toJSON(logo_uri, auto_unbox = TRUE), jsonlite::toJSON(payoff_uri, auto_unbox = TRUE)))),
    htmltools::tags$script(htmltools::HTML(WS_JS))
  )
}

# ---------------------------------------------------------------- server side

.ws_api <- function(method, path, body = NULL) {
  token <- .ws_cache$token
  if (is.null(token)) {
    token <- trimws(paste(readLines(Sys.getenv("WS_TOKEN_FILE", "/run/ws/token"), warn = FALSE), collapse = ""))
    .ws_cache$token <- token
  }
  req <- httr2::request(Sys.getenv("WS_API", "http://api:8000")) |>
    httr2::req_url_path_append(path) |>
    httr2::req_method(method) |>
    httr2::req_auth_bearer_token(token) |>
    httr2::req_timeout(10) |>
    httr2::req_error(is_error = function(resp) FALSE)
  if (!is.null(body)) req <- httr2::req_body_json(req, body, auto_unbox = TRUE, digits = NA)
  resp <- httr2::req_perform(req)
  list(status = httr2::resp_status(resp), body = httr2::resp_body_json(resp))
}

#' Follow the facilitator: push the participant's state to the page every few seconds, and save answers.
ws_server <- function(session, input = session$input) {
  # If the connection drops for a moment (a wifi hiccup), the page reconnects to this same session. If the session
  # is gone (ShinyProxy restarted to load new accounts), the page asks to reload (WS_JS, 'shiny:disconnected').
  session$allowReconnect(TRUE)
  push <- function() {
    me <- tryCatch(.ws_api("GET", "me"), error = function(e) NULL)
    if (is.null(me) || me$status != 200) {
      session$sendCustomMessage("ws_offline", list(
        message = "Connection lost. Your work is safe; we are reconnecting..."))
    } else {
      session$sendCustomMessage("ws_state", me$body)
    }
  }
  shiny::observe({
    shiny::invalidateLater(WS_POLL_MS, session)
    push()
  })
  shiny::observeEvent(input$ws_save, {
    s <- input$ws_save
    out <- tryCatch(.ws_api("POST", "answer", list(id = s$id, value = s$value)),
                    error = function(e) list(status = 0, body = list(error = "Could not save: no connection. Try again in a moment.")))
    session$sendCustomMessage("ws_saved", list(id = s$id, ok = out$status == 200,
                                                error = out$body$error %||% NULL))
    push()
  })
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# ---------------------------------------------------------------- browser side
# Hanze colours (brand portal): oranje #EE7F00, donkergroen #628C5F, lichtblauw #B1CEDE, paars #9E6697,
# lichtgroen #9CC489, donkerblauw #578494, grijsgroen #C4C6B1, geel #DEC437, roze #E0B6CE.
# Text on orange is dark (white on #EE7F00 is too low in contrast); links use a darker shade of donkerblauw.

WS_CSS <- "
:root {
  --ws-orange: #EE7F00; --ws-orange-dark: #C96A00; --ws-button: #B35C00; --ws-button-hover: #8F4A00; --ws-green: #628C5F; --ws-lightgreen: #9CC489;
  --ws-lightblue: #B1CEDE; --ws-purple: #9E6697; --ws-darkblue: #578494; --ws-link: #41636F;
  --ws-greygreen: #C4C6B1; --ws-yellow: #DEC437; --ws-pink: #E0B6CE; --ws-ink: #1D1D1B; --ws-muted: #5F6155;
  --ws-paper: #F4F4F5;
}
body { font-size: 17px; line-height: 1.6; color: var(--ws-ink); background: #fff; }
a, a:visited { color: var(--ws-link); }
h2 { font-weight: 700; margin-top: 0.4em; padding-bottom: 0.3em; border-bottom: 4px solid var(--ws-orange); display: inline-block; }
h3 { font-weight: 700; margin-top: 1.6em; }
p code, li code { color: var(--ws-ink); background: #ECECEE; border-radius: 4px; padding: 1px 5px; }
blockquote { border-left: 5px solid var(--ws-lightblue); background: #F3F8FB; font-size: 16px; padding: 0.8em 1.1em; }

/* Sidebar: logo, parts with their status, sign out. learnr's 'Start Over' (it erases all work) is removed, and so is
   its progress strip behind each part (with its negative margins it showed as stray marks at the left edge). */
.topicsList { background: #fff; border-right: 1px solid #E2E2E6; padding-left: 0 !important; }
.topicsHeader { display: block !important; padding: 18px 16px 12px; }
.topicsHeader .ws-logo { display: block; width: 130px; max-width: 100%; height: auto; margin: 0 0 26px; }
.topicsHeader .tutorialTitle { display: block; font-size: 19px; line-height: 1.3; font-weight: 700; color: var(--ws-ink);
  margin: 0; overflow-wrap: anywhere; }
.topicsList .topic { background-image: none !important; background-color: transparent !important; margin-left: 0 !important;
  padding-left: 0 !important; border-bottom: 1px solid #E7E7EA; line-height: 1.4; }
.topicsList .topic a { color: var(--ws-ink) !important; font-size: 16px; border: 0 !important; border-radius: 0 !important;
  margin-left: 0 !important; padding: 11px 14px 11px 16px !important; display: flex; align-items: center; gap: 8px; }
.topicsList .topic a:hover { background: #F4F4F5 !important; }
.topicsList .topic.current a { background: #FDF3E6 !important; box-shadow: inset 5px 0 0 var(--ws-orange); font-weight: 700; }
.topicsList .topic.ws-locked a { color: var(--ws-muted) !important; }
.ws-mark { margin-left: auto; flex-shrink: 0; }
.ws-topic-icon { display: inline-block; width: 14px; height: 16px; opacity: 0.7;
  background: no-repeat center/contain url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 14 16'%3E%3Crect x='1' y='7' width='12' height='9' rx='2' fill='%235F6155'/%3E%3Cpath d='M4 7V5a3 3 0 0 1 6 0v2' stroke='%235F6155' stroke-width='2' fill='none'/%3E%3C/svg%3E\"); }
.ws-topic-new { background: #FDF3E6; color: var(--ws-button); border: 1px solid var(--ws-orange); font-size: 12px; font-weight: 700;
  border-radius: 10px; padding: 0 8px; }
.ws-topic-done { color: var(--ws-green); font-weight: 700; font-size: 18px; }
.topicsFooter { padding: 4px 16px 16px; }
.topicsFooter .resetButton { display: none !important; }
.ws-signout { display: inline-block; margin-top: 10px; font-size: 14px; color: var(--ws-muted) !important; }
.section.level3.done h3 { background-image: none !important; padding-left: 0 !important; }

/* Code boxes: the Run Code button is the obvious action. learnr keeps the class 'disabled' on it at rest (the button
   works anyway), and Bootstrap shows a 'not allowed' cursor for that: show the normal hand instead. */
.tutorial-exercise-input { border: 1px solid #D9D9DE; border-radius: 8px; overflow: hidden; }
.tutorial-exercise-input .panel-heading { background: #F4F4F5; border-bottom: 1px solid #E2E2E6; }
.btn-tutorial-run, .btn-tutorial-run.disabled { background: var(--ws-button) !important; border-color: var(--ws-button) !important;
  color: #fff !important; font-weight: 700; font-size: 15px !important; padding: 5px 16px !important; opacity: 1 !important;
  cursor: pointer !important; }
.btn-tutorial-run:hover { background: var(--ws-button-hover) !important; }
.btn-tutorial-hint { font-size: 13px !important; }
/* Hints: dark text on a light orange background (learnr's default is too faint to read). */
.tutorial-hint-panel, .tutorial-hint-panel *, .tutorial-hint, .tutorial-hint *, .tutorial-solution,
.tutorial-exercise .alert, .popover .popover-content, .tutorial-exercise-hint {
  color: var(--ws-ink) !important; opacity: 1 !important; }
.tutorial-hint-panel, .tutorial-hint { background: #FDF3E6 !important; border: 1px solid #F5C58A !important; border-radius: 6px; }
.tutorial-hint-panel .tutorial-hint { border: 0 !important; }
/* learnr shows the hint inside the output area, which Shiny fades (opacity 0.3) until the code has run. */
.tutorial-exercise-output-frame.recalculating:has(.tutorial-hint-panel) { opacity: 1 !important; }
.btn-tutorial-start-over { font-size: 13px !important; }
.ace_editor { font-size: 15px !important; }
.tutorial-exercise-output { margin-top: 6px; }

/* Tables in results (ws_print_table): all columns, scrolled with the mouse wheel or trackpad, header kept in view. */
.ws-table { max-height: 460px; overflow: auto; border: 1px solid #D9D9DE; border-radius: 6px; margin: 6px 0 2px; }
.ws-table table { border-collapse: separate; border-spacing: 0; font-size: 14px; width: max-content; min-width: 100%; margin: 0; }
.ws-table th, .ws-table td { padding: 5px 12px; white-space: nowrap; border-bottom: 1px solid #ECECEE; text-align: left; }
.ws-table th { position: sticky; top: 0; background: #F4F4F5; font-weight: 700; z-index: 1; border-bottom: 1px solid #D9D9DE; }
.ws-table th small { display: block; font-weight: 400; color: var(--ws-muted); }
.ws-table td.ws-num { text-align: right; font-variant-numeric: tabular-nums; }
.ws-table th.ws-num { text-align: right; }
.ws-table td.ws-na { color: #9A9C90; }
.ws-table tbody tr:hover td { background: #FBF6EE; }
.ws-table-note { font-size: 14px; color: var(--ws-muted); margin: 0 0 8px; }

/* Previous/Next part buttons. */
.topicActions .btn { font-size: 15px; padding: 7px 18px; border-radius: 6px; }
.topicActions .btn-primary { background: var(--ws-button); border-color: var(--ws-button); color: #fff; font-weight: 700; }
.topicActions .btn-primary:hover { background: var(--ws-button-hover); }

/* Questions. */
.ws-question { margin: 1.6em 0; padding: 18px 22px; background: #fff; border: 1px solid #D9D9DE;
  border-left: 6px solid var(--ws-orange); border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
.ws-question-label { font-size: 13px; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: var(--ws-orange-dark); }
.ws-prompt { font-size: 18px; font-weight: 600; margin: 4px 0 12px; }
.ws-number { display: flex; align-items: center; gap: 10px; }
.ws-number .ws-input { max-width: 14em; font-size: 17px; height: 42px; }
.ws-unit { color: var(--ws-muted); }
textarea.ws-input { font-size: 17px; }
.ws-option { display: flex; align-items: center; gap: 10px; font-weight: normal; margin: 4px 0; padding: 8px 12px;
  border: 1px solid #E2E2E6; border-radius: 6px; cursor: pointer; }
.ws-option:hover { background: #FBF6EE; }
.ws-option input { margin: 0; width: 18px; height: 18px; accent-color: var(--ws-orange); }
.ws-option:has(input:checked) { border-color: var(--ws-orange); background: #FDF3E6; }
.ws-actions { margin-top: 14px; display: flex; align-items: center; gap: 14px; flex-wrap: wrap; }
.ws-save { background: var(--ws-button); color: #fff; border: 1px solid var(--ws-button); border-radius: 6px;
  font-size: 16px; font-weight: 700; padding: 8px 20px; cursor: pointer; }
.ws-save:hover { background: var(--ws-button-hover); }
.ws-status { font-size: 15px; color: var(--ws-muted); }
.ws-status.ws-saved { color: var(--ws-green); font-weight: 600; }
.ws-status.ws-dirty { color: #7A6400; }
.ws-status.ws-error { color: var(--ws-purple); font-weight: 600; }
.ws-feedback:empty { display: none; }
.ws-feedback { margin-top: 14px; padding: 12px 16px; border-radius: 6px; border-left: 5px solid var(--ws-lightblue); background: #F3F8FB; }
.ws-feedback.ws-right { border-left-color: var(--ws-green); background: #EEF5EA; }
.ws-feedback.ws-wrong { border-left-color: var(--ws-purple); background: #F8EEF4; }
.ws-feedback-title { font-weight: 700; display: block; }
.ws-feedback-explain { display: block; margin-top: 4px; }
.ws-feedback.ws-unanswered { border-left-color: var(--ws-greygreen); background: var(--ws-paper); }
.ws-payoff { display: block; width: 100%; height: auto; margin: 20px 0 6px; }

/* A part that is not open yet. */
.ws-section:not(.ws-open) > * { display: none !important; }
.ws-section:not(.ws-open)::before { content: 'This part is not open yet. Your facilitator will open it during the workshop; it will appear here by itself.';
  display: block; padding: 22px 24px 22px 62px; background: var(--ws-paper) no-repeat 24px center / 22px 25px; border: 2px dashed #CFCFD4;
  border-radius: 10px; color: var(--ws-muted); font-size: 17px;
  background-image: url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 14 16'%3E%3Crect x='1' y='7' width='12' height='9' rx='2' fill='%235F6155'/%3E%3Cpath d='M4 7V5a3 3 0 0 1 6 0v2' stroke='%235F6155' stroke-width='2' fill='none'/%3E%3C/svg%3E\"); }

/* One notice at a time, top right: something new is open, or feedback is ready. */
#ws-notice { display: none; position: fixed; top: 16px; right: 16px; z-index: 2000; max-width: 380px; background: #fff;
  border: 1px solid #D9D9DE; border-left: 6px solid var(--ws-yellow); border-radius: 8px; padding: 14px 16px;
  box-shadow: 0 6px 20px rgba(0,0,0,0.12); font-size: 16px; }
#ws-notice button { margin-top: 10px; margin-right: 8px; border-radius: 6px; padding: 6px 14px; font-size: 15px; border: 1px solid #CFCFD4; background: #fff; }
#ws-notice .ws-go { background: var(--ws-button); border-color: var(--ws-button); color: #fff; font-weight: 700; }
#ws-offline { display: none; position: fixed; bottom: 16px; right: 16px; z-index: 2000; padding: 10px 16px;
  background: #FBF7E3; border: 1px solid var(--ws-yellow); border-radius: 8px; font-size: 15px; }
/* Connection lost for good: in the middle of the screen, above Shiny's grey overlay. */
#ws-offline.ws-lost { top: 50%; left: 50%; bottom: auto; right: auto; transform: translate(-50%, -50%); z-index: 100000;
  max-width: 440px; padding: 22px 24px; font-size: 17px; background: #fff; border-left: 6px solid var(--ws-orange);
  box-shadow: 0 6px 24px rgba(0,0,0,0.2); }
#ws-offline .ws-reload { margin-top: 14px; background: var(--ws-button); color: #fff; border: 0; border-radius: 6px;
  font-size: 16px; font-weight: 700; padding: 8px 20px; cursor: pointer; }
"

WS_JS <- "
(function() {
  var dirty = {}, first = true, prevOpen = null, prevFeedback = {}, visited = {};
  function $q(id) { return document.querySelector('.ws-question[data-id=\"' + id + '\"]'); }
  function topics() { return Array.from(document.querySelectorAll('.section.level2')); }
  function topicLinks() { return Array.from(document.querySelectorAll('.topicsList .topic')); }
  function topicOf(el) { return topics().indexOf(el.closest('.section.level2')); }
  function topicTitle(i) { var h = topics()[i] && topics()[i].querySelector('h2'); return h ? h.textContent : ''; }
  function goTo(i) { var l = topicLinks()[i]; if (l) l.querySelector('a').click(); window.scrollTo(0, 0); }

  function value(el) {
    var t = el.dataset.type;
    if (t === 'choice') { var c = el.querySelector('input:checked'); return c ? c.value : null; }
    var v = el.querySelector('.ws-input').value;
    if (t === 'number') return v === '' ? null : Number(v);
    return v.trim() === '' ? null : v;
  }
  function setValue(el, v) {
    if (el.dataset.type === 'choice') el.querySelectorAll('input').forEach(function(i) { i.checked = (i.value === v); });
    else el.querySelector('.ws-input').value = v;
  }
  function status(el, text, cls) {
    var s = el.querySelector('.ws-status'); s.textContent = text; s.className = 'ws-status' + (cls ? ' ' + cls : '');
  }
  function resizeEditors(root) {
    if (window.ace) root.querySelectorAll('.ace_editor').forEach(function(e) { try { ace.edit(e).resize(true); } catch (err) {} });
    window.dispatchEvent(new Event('resize'));
  }

  var notice;
  function notify(text, topicIndex) {
    notice.innerHTML = '';
    var p = document.createElement('div'); p.textContent = text; notice.appendChild(p);
    if (topicIndex >= 0) {
      var go = document.createElement('button'); go.className = 'ws-go'; go.textContent = 'Go there';
      go.onclick = function() { notice.style.display = 'none'; goTo(topicIndex); }; notice.appendChild(go);
    }
    var ok = document.createElement('button'); ok.textContent = 'OK';
    ok.onclick = function() { notice.style.display = 'none'; }; notice.appendChild(ok);
    notice.style.display = 'block';
  }

  // Sidebar: lock, 'New' (opened but not visited yet), or a tick (all questions in that part saved).
  function updateSidebar(open, answers) {
    var links = topicLinks();
    topics().forEach(function(t, i) {
      var li = links[i]; if (!li) return;
      var gate = t.querySelector('.ws-section'), isOpen = !gate || open.indexOf(gate.dataset.section) >= 0;
      if (li.classList.contains('current')) visited[i] = true;
      var qs = Array.from(t.querySelectorAll('.ws-question')).map(function(q) { return q.dataset.id; });
      var done = qs.length > 0 && qs.every(function(id) { return id in answers; });
      li.classList.toggle('ws-locked', !isOpen);
      var kind = !isOpen ? 'ws-topic-icon' : done ? 'ws-topic-done' : (gate && !visited[i]) ? 'ws-topic-new' : '';
      var a = li.querySelector('a'), old = a.querySelector('.ws-mark');
      if (old && old.dataset.kind === kind) return;   // unchanged: leave the page alone
      if (old) old.remove();
      if (!kind) return;
      var mark = document.createElement('span'); mark.className = 'ws-mark ' + kind; mark.dataset.kind = kind;
      if (kind === 'ws-topic-icon') mark.title = 'Not open yet';
      if (kind === 'ws-topic-done') { mark.textContent = '\\u2713'; mark.title = 'All questions answered'; }
      if (kind === 'ws-topic-new') mark.textContent = 'New';
      a.appendChild(mark);
    });
  }

  document.addEventListener('click', function(ev) {
    var b = ev.target.closest('.ws-save'); if (!b) return;
    var el = b.closest('.ws-question'), v = value(el);
    if (v === null) { status(el, el.dataset.type === 'choice' ? 'Choose an answer first.' : 'Fill in an answer first.', 'ws-error'); return; }
    status(el, 'Saving...');
    Shiny.setInputValue('ws_save', {id: el.dataset.id, value: v}, {priority: 'event'});
  });
  function edited(ev) {
    var el = ev.target.closest('.ws-question'); if (!el) return;
    dirty[el.dataset.id] = true;
    var fbox = el.querySelector('.ws-feedback'); fbox.innerHTML = ''; fbox.className = 'ws-feedback'; fbox.dataset.stamp = '';
    status(el, 'Not saved yet. Click Save answer.', 'ws-dirty');
  }
  // Enter saves the answer, as the Save answer button does (in a text box, Shift+Enter starts a new line).
  document.addEventListener('keydown', function(ev) {
    if (ev.key !== 'Enter' || ev.shiftKey || ev.isComposing) return;
    var el = ev.target.closest('.ws-question'); if (!el || !ev.target.matches('input, textarea')) return;
    ev.preventDefault();
    el.querySelector('.ws-save').click();
  });
  document.addEventListener('input', edited);
  document.addEventListener('change', function(ev) { if (ev.target.type === 'radio') edited(ev); });
  document.addEventListener('click', function(ev) {
    var li = ev.target.closest('.topicsList .topic'); if (li) visited[topicLinks().indexOf(li)] = true;
  });

  function init() {
    if (!window.Shiny || !Shiny.addCustomMessageHandler || !document.querySelector('.topicsHeader')) { return setTimeout(init, 100); }
    var header = document.querySelector('.topicsHeader');
    if (window.WS_LOGO) { var img = document.createElement('img'); img.className = 'ws-logo'; img.src = WS_LOGO; img.alt = 'Hanze'; header.prepend(img); }
    var footer = document.querySelector('.topicsFooter');
    if (footer) { var so = document.createElement('a'); so.className = 'ws-signout'; so.href = '/logout'; so.target = '_top'; so.textContent = 'Sign out'; footer.appendChild(so);
      if (window.WS_PAYOFF) { var po = document.createElement('img'); po.className = 'ws-payoff'; po.src = WS_PAYOFF;
                              po.alt = 'share your talent. move the world.'; footer.appendChild(po); } }
    notice = document.createElement('div'); notice.id = 'ws-notice'; notice.setAttribute('role', 'status'); document.body.appendChild(notice);
    var off = document.createElement('div'); off.id = 'ws-offline'; document.body.appendChild(off);

    // The connection is gone for good (Shiny gave up reconnecting): instead of Shiny's grey screen alone, say what to do.
    $(document).on('shiny:disconnected', function() {
      setTimeout(function() {
        if (Shiny.shinyapp.isConnected()) return;
        off.innerHTML = '';
        var t = document.createElement('div'); t.textContent = 'The connection to the workshop was lost. Reload the page to continue: your answers and code are kept.';
        var b = document.createElement('button'); b.className = 'ws-reload'; b.textContent = 'Reload page';
        b.onclick = function() { window.location.reload(); };
        off.appendChild(t); off.appendChild(b); off.classList.add('ws-lost'); off.style.display = 'block';
      }, 4000);
    });
    Shiny.addCustomMessageHandler('ws_offline', function(m) { off.classList.remove('ws-lost'); off.textContent = m.message; off.style.display = 'block'; });
    Shiny.addCustomMessageHandler('ws_saved', function(m) {
      var el = $q(m.id); if (!el) return;
      if (m.ok) { dirty[m.id] = false; status(el, '\\u2713 Saved', 'ws-saved'); }
      else { status(el, m.error || 'Not saved. Try again.', 'ws-error'); }
    });
    Shiny.addCustomMessageHandler('ws_state', function(m) {
      off.style.display = 'none'; off.classList.remove('ws-lost');
      var open = m.open || [], answers = Array.isArray(m.answers) ? {} : (m.answers || {}),
          fb = Array.isArray(m.feedback) ? {} : (m.feedback || {});
      var opened = [];
      document.querySelectorAll('.ws-section').forEach(function(s) {
        var isOpen = open.indexOf(s.dataset.section) >= 0, was = s.classList.contains('ws-open');
        s.classList.toggle('ws-open', isOpen);
        if (isOpen && !was) { resizeEditors(s); if (!first) opened.push(topicOf(s)); }
      });
      Object.keys(answers).forEach(function(id) {
        var el = $q(id); if (!el || dirty[id]) return;
        if (first) { setValue(el, answers[id]); status(el, '\\u2713 Saved', 'ws-saved'); }
      });
      var newFeedback = [];
      document.querySelectorAll('.ws-question').forEach(function(el) {
        var id = el.dataset.id, box = el.querySelector('.ws-feedback'), f = fb[id];
        if (dirty[id]) return;
        var stamp = f ? String(f.ok) + '|' + f.text : '';
        if (box.dataset.stamp === stamp) return;   // unchanged: leave the page alone
        box.dataset.stamp = stamp;
        if (!f) { box.innerHTML = ''; box.className = 'ws-feedback'; return; }
        if (!first && !prevFeedback[id]) newFeedback.push(topicOf(el));
        var title = f.unanswered ? 'Not answered' : f.ok === true ? '\\u2713 Correct' : f.ok === false ? '\\u00D7 Not quite' : 'Feedback';
        box.className = 'ws-feedback' + (f.unanswered ? ' ws-unanswered' : f.ok === true ? ' ws-right' : f.ok === false ? ' ws-wrong' : '');
        box.innerHTML = '';
        var t = document.createElement('span'); t.className = 'ws-feedback-title'; t.textContent = title;
        box.appendChild(t);
        if (f.text) { var b = document.createElement('span'); b.textContent = f.text; box.appendChild(b); }
        // The explanation is for those who need it: a wrong answer, no answer, or no other text.
        if (f.explain && (f.unanswered || f.ok === false || !f.text)) {
          var e = document.createElement('span'); e.className = 'ws-feedback-explain'; e.textContent = f.explain; box.appendChild(e);
        }
      });
      prevFeedback = fb;
      updateSidebar(open, answers);
      // The facilitator can turn the notices off (m.notices false); the sidebar still shows what is new.
      if (m.notices === false) notice.style.display = 'none';
      else if (opened.length) notify('\\u201C' + topicTitle(opened[0]) + '\\u201D is now open.', opened[0]);
      else if (newFeedback.length) notify('Feedback on your answers is ready in \\u201C' + topicTitle(newFeedback[0]) + '\\u201D.', newFeedback[0]);
      first = false;
    });
  }
  init();
})();
"
