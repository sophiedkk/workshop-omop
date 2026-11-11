# The facilitator's page: open parts and show feedback (for everyone, or for one participant), and follow
# progress and answers. A client of the api with the admin token; it holds no state of its own.
# Access is restricted by ShinyProxy (group admin); this app has no login of its own.
#
# Designed for use during a live session: one obvious button per step, everything else at a glance.
#
# Environment: WS_API (default http://api:8000), WS_TOKEN_FILE (admin token, default /run/ws/token).

library(shiny)
library(bslib)
source(file.path(Sys.getenv("WS_HOME", "/srv/workshop"), "app", "core.R"))
REFRESH_MS <- 3000

# ---------------------------------------------------------------- api

admin_token <- trimws(paste(readLines(Sys.getenv("WS_TOKEN_FILE", "/run/ws/token"), warn = FALSE), collapse = ""))
api <- function(method, path, body = NULL) {
  req <- httr2::request(Sys.getenv("WS_API", "http://api:8000")) |>
    httr2::req_url_path_append(path) |> httr2::req_method(method) |>
    httr2::req_auth_bearer_token(admin_token) |> httr2::req_timeout(10)
  if (!is.null(body)) req <- httr2::req_body_json(req, body, auto_unbox = TRUE)
  httr2::resp_body_json(httr2::req_perform(req))
}

#' Everything the page shows, from the api: releases and answers as data frames.
overview <- function() {
  o <- api("GET", "admin/overview")
  rel <- do.call(rbind, c(lapply(o$releases, as.data.frame), list(data.frame(key = character(), target = character()))))
  answers <- data.frame(participant = vapply(o$answers, `[[`, "", "participant"),
                        question = vapply(o$answers, `[[`, "", "question"),
                        saved_at = vapply(o$answers, `[[`, "", "saved_at"))
  answers$value <- lapply(o$answers, `[[`, "value")
  online <- vapply(o$presence %||% list(), function(x) isTRUE(x$online), TRUE)
  names(online) <- vapply(o$presence %||% list(), `[[`, "", "id")
  full <- vapply(o$presence %||% list(), function(x) x$name %||% x$id, "")
  names(full) <- names(online)
  list(def = o$definition, key = o$key, rel = rel, answers = answers, pids = unlist(o$participants) %||% character(),
       online = online, full = full)
}

first <- overview()
def <- first$def
key <- first$key

# ---------------------------------------------------------------- helpers

section_keys <- function(sid, part) {
  if (part == "open") return(if (isTRUE(def$sections[[sid]]$gated)) paste0("open:", sid) else character())
  qs <- names(Filter(function(q) ws_has_feedback(key, q$id), ws_section_questions(def, sid)))
  if (length(qs)) paste0("feedback:", qs) else character()
}
is_on <- function(keys, target, rel) length(keys) > 0 && all(keys %in% rel$key[rel$target == target])

#' A release button: data attributes say what to release; the page's script sends it.
rel_button <- function(keys, target, on, label, primary = FALSE) {
  tags$button(type = "button", class = paste("btn rel-btn", if (primary) "btn-primary" else "btn-outline-secondary"),
              `data-keys` = paste(keys, collapse = ","), `data-target` = target, `data-on` = tolower(on), label)
}
chip <- function(text, cls) tags$span(class = paste("ws-chip", cls), text)

#' One row per part: its state and the buttons that change it. Fixed columns (status, button, status, button), so
#' the buttons stay in the same place whatever the status says.
step_row <- function(s, rel, target = ALL) {
    ok <- section_keys(s$id, "open"); fk <- section_keys(s$id, "feedback")
    open_now <- !length(ok) || is_on(ok, target, rel)
    open_chip <- if (!length(ok)) chip("Always open", "ws-chip-open")
                 else if (open_now) chip("Open", "ws-chip-open") else chip("Not open", "ws-chip-locked")
    open_btn <- if (!length(ok)) NULL
                else if (open_now) rel_button(ok, target, FALSE, "Close")
                else rel_button(ok, target, TRUE, "Open", primary = TRUE)
    fb_on <- is_on(fk, target, rel)
    fb_chip <- if (!length(fk)) chip("No feedback", "ws-chip-none")
               else if (fb_on) chip("Shown", "ws-chip-open") else chip("Not shown", "ws-chip-locked")
    fb_btn <- if (!length(fk)) NULL
              else if (fb_on) rel_button(fk, target, FALSE, "Hide")
              else rel_button(fk, target, TRUE, "Show", primary = open_now)
    tags$tr(tags$th(s$title), tags$td(open_chip), tags$td(open_btn), tags$td(fb_chip), tags$td(fb_btn))
}

#' The pop-up notices on participants' pages ("... is now open", "Feedback is ready"): on unless turned off.
notices_ui <- function(rel) {
  off <- is_on(NOTICES_OFF, ALL, rel)
  tags$div(class = "ws-notices",
    tags$span("Pop-up notices for participants (\u201Cnow open\u201D, \u201Cfeedback is ready\u201D): "),
    if (off) chip("Off", "ws-chip-locked") else chip("On", "ws-chip-open"),
    rel_button(NOTICES_OFF, ALL, !off, if (off) "Turn on" else "Turn off"),
    tags$div(class = "text-muted small", "With notices off, participants still see new parts and feedback on the page itself."))
}

#' One participant's row in the progress grid.
progress_row <- function(p, s) {
  released <- unique(s$rel$key[s$rel$target %in% c(ALL, p)])
  on <- isTRUE(s$online[p])
  who <- if (!is.na(s$full[p]) && nzchar(s$full[p])) unname(s$full[p]) else p
  tags$tr(tags$td(who, if (!identical(who, p)) tags$div(class = "text-muted small", p)),
          tags$td(tags$span(class = paste("ws-dot", if (on) "on")), if (on) "yes" else "no"),
          lapply(def$sections, function(sec) {
    qs <- names(ws_section_questions(def, sec$id))
    n <- sum(s$answers$participant == p & s$answers$question %in% qs)
    if (!ws_is_open(def, released, sec$id)) return(tags$td(class = "ws-cell-locked", "–"))
    if (!length(qs)) return(tags$td(class = "ws-cell-open", "open"))
    tags$td(class = if (n == length(qs)) "ws-cell-done" else "ws-cell-open", sprintf("%d/%d", n, length(qs)))
  }))
}

# Thousands separators only for large numbers (a year should read 2023, not 2,023).
num <- function(x) format(x, big.mark = if (abs(as.numeric(x)) >= 10000) "," else "", scientific = FALSE, trim = TRUE)

summary_ui <- function(q, answers, n_total, big = FALSE) {
  a <- answers[answers$question == q$id, , drop = FALSE]
  vals <- a$value
  w <- if (big) 520 else 260
  k <- key[[q$id]]
  correct <- if (is.null(k)) NULL
             else if (q$type == "number") tags$p(class = "ws-correct", "Correct answer: ", tags$strong(num(k$expected)))
             else tags$p(class = "ws-correct", "Correct answer: ",
                         tags$strong(paste(names(Filter(function(v) identical(v[[1]], "right"), k$options)), collapse = ", ")))
  body <- if (!nrow(a) && q$type != "choice") tags$p(class = "text-muted", "No answers yet.") else switch(q$type,
    choice = {
      opts <- unlist(q$options)
      counts <- table(factor(unlist(vals), levels = opts))
      right <- function(o) identical(key[[q$id]]$options[[o]][[1]], "right")
      tags$table(class = "ws-bars", lapply(opts, function(o) {
        n <- counts[[o]]
        tags$tr(tags$td(class = "ws-bar-label", o, if (right(o)) tags$span(class = "ws-right", " ✓ correct")),
                tags$td(tags$div(class = paste("ws-bar", if (right(o)) "ws-bar-right"),
                                 style = sprintf("width:%dpx", round(w * n / max(1, max(counts)))))),
                tags$td(class = "ws-bar-n", n))
      }))
    },
    number = {
      v <- as.numeric(unlist(vals))
      right <- if (!is.null(k)) sum(abs(v - k$expected) <= (k$tolerance %||% 0)) else NA
      common <- utils::head(sort(table(v), decreasing = TRUE), 5)
      tagList(
        if (!is.na(right)) tags$p(class = "ws-right-line", sprintf("%d of %d right", right, length(v))),
        tags$p(class = "text-muted small", "Most given: ",
               paste(sprintf("%s (%d×)", vapply(as.numeric(names(common)), num, ""), as.integer(common)), collapse = ", ")))
    },
    text = {
      shown <- utils::head(a[order(a$saved_at, decreasing = TRUE), ], if (big) 12 else 6)
      tagList(lapply(seq_len(nrow(shown)), function(i) tags$blockquote(class = "ws-quote", unlist(shown$value[i]),
                                                                        if (!big) tags$small(class = "text-muted", " — ", shown$participant[i]))),
              if (nrow(a) > nrow(shown)) tags$p(class = "text-muted small", sprintf("and %d more", nrow(a) - nrow(shown))))
    })
  tags$div(class = if (big) "ws-present" else "ws-summary",
    tags$div(class = "d-flex justify-content-between align-items-start gap-3",
      tags$div(tags$div(class = "ws-q", HTML(commonmark::markdown_html(q$prompt))),
               tags$div(class = "text-muted small", sprintf("%d of %d answered", nrow(a), n_total)), correct),
      if (!big) tags$button(type = "button", class = "btn btn-sm btn-outline-secondary present-btn", `data-id` = q$id, "Show on screen")),
    body)
}

# ---------------------------------------------------------------- page

theme <- bs_theme(version = 5, primary = "#B35C00", secondary = "#578494", success = "#628C5F", info = "#B1CEDE",
                  warning = "#DEC437", danger = "#9E6697", bg = "#FFFFFF", fg = "#1D1D1B",
                  "link-color" = "#41636F", "border-radius" = "0.5rem", "font-size-base" = "1rem")
logo <- file.path(Sys.getenv("WS_HOME", "/srv/workshop"), "branding", "hanze-logo-dark.svg")   # for the dark header
logo_tag <- if (file.exists(logo)) tags$img(class = "ws-logo", alt = "Hanze",
  src = paste0("data:image/svg+xml;base64,", jsonlite::base64_enc(readBin(logo, "raw", file.size(logo)))))

ui <- page_fluid(
  theme = theme, title = paste(def$title, "- facilitator"),
  tags$head(tags$style(HTML("
    body { background: #F4F4F5; }
    .recalculating { opacity: 1 !important; transition: none !important; }   /* no fade while a part redraws */
    .ws-header { display: flex; align-items: center; gap: 20px; padding: 14px 22px; margin: 0 -12px 16px;
                 background: #1D1D1B; color: #fff; border-bottom: 4px solid #EE7F00; }
    .ws-logo { height: 40px; }
    .ws-header h1 { font-size: 1.4rem; font-weight: 700; margin: 0; color: #fff; }
    .ws-header .ws-role { color: #EE7F00; font-weight: 700; text-transform: uppercase; letter-spacing: .06em; font-size: .8rem; }
    .card { margin-bottom: 16px; }
    .ws-steps { table-layout: fixed; width: 100%; }
    .ws-notices { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 12px; padding-top: 4px; }
    .ws-notices .btn { padding: 2px 12px; }
    .ws-notices .text-muted { flex-basis: 100%; }
    .ws-steps col.c-part { width: 34%; } .ws-steps col.c-chip { width: 19%; } .ws-steps col.c-btn { width: 14%; }
    .ws-steps th { font-weight: 600; }
    .ws-steps thead th { font-size: .8rem; text-transform: uppercase; letter-spacing: .05em; color: #5F6155; font-weight: 700; }
    .ws-chip { white-space: nowrap; }
    .ws-steps td .btn { width: 100%; white-space: nowrap; padding-left: 4px; padding-right: 4px; }
    .ws-chip-none { background: transparent; color: #8A8C78; font-weight: 400; }
    .ws-correct { margin: 4px 0 0; font-size: .95rem; }
    .ws-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 6px; background: #C4C6B1; }
    .ws-dot.on { background: #628C5F; }
    .ws-chip { display: inline-block; font-size: .8rem; font-weight: 600; padding: 2px 10px; border-radius: 12px; }
    .ws-chip-open { background: #E6F0E1; color: #3E5C3C; }
    .ws-chip-locked { background: #ECECEE; color: #5F6155; }
    .ws-grid td, .ws-grid th { text-align: center; font-size: .9rem; padding: 6px 8px; }
    .ws-grid th:first-child, .ws-grid td:first-child { text-align: left; font-weight: 600; }
    .ws-cell-locked { --bs-table-bg: #ECECEE; --bs-table-color: #8A8C78; }
    .ws-cell-open { --bs-table-bg: #FDF3E6; }
    .ws-cell-done { --bs-table-bg: #E6F0E1; --bs-table-color: #3E5C3C; font-weight: 600; }
    .ws-summary { padding: 14px 0; border-bottom: 1px solid #E7E7EA; }
    .ws-q p { margin: 0; font-weight: 600; }
    .ws-bars td { padding: 3px 8px; vertical-align: middle; }
    .ws-bar { height: 18px; background: #578494; border-radius: 3px; min-width: 2px; }
    .ws-bar-right { background: #628C5F; }
    .ws-right { color: #3E5C3C; font-weight: 700; }
    .ws-right-line { font-size: 1.05rem; font-weight: 600; margin: 6px 0 2px; }
    .ws-quote { border-left: 4px solid #B1CEDE; padding: 4px 12px; margin: 6px 0; background: #F3F8FB; }
    .ws-present { font-size: 1.5rem; } .ws-present .ws-q p { font-size: 2rem; margin-bottom: 18px; }
    .ws-present .ws-bar { height: 34px; } .ws-present .ws-right-line { font-size: 2rem; }
  ")),
  tags$script(HTML("
    document.addEventListener('click', function(ev) {
      var b = ev.target.closest('.rel-btn');
      if (b) { Shiny.setInputValue('release', {keys: b.dataset.keys.split(','), target: b.dataset.target,
                                               on: b.dataset.on === 'true'}, {priority: 'event'}); return; }
      var p = ev.target.closest('.present-btn');
      if (p) Shiny.setInputValue('present', p.dataset.id, {priority: 'event'});
    });"))),
  tags$div(class = "ws-header", logo_tag, tags$div(tags$div(class = "ws-role", "Facilitator"), tags$h1(def$title))),
  # Every piece of the page is its own output, and is redrawn only when its own content changed (see show() in
  # the server): one participant saving an answer redraws their row and that question, nothing else.
  layout_columns(fill = FALSE,
    value_box(title = "Participants", value = uiOutput("n_participants", inline = TRUE), theme = "white"),
    value_box(title = "Online now", value = uiOutput("n_online", inline = TRUE), theme = "white"),
    value_box(title = "Parts open", value = uiOutput("n_open", inline = TRUE), theme = "white"),
    value_box(title = "Feedback shown", value = uiOutput("n_feedback", inline = TRUE), theme = "white")),
  # One column, so the page also works on half a screen.
  card(card_header("Workshop steps"),
       tags$table(class = "table align-middle ws-steps",
         tags$colgroup(tags$col(class = "c-part"), tags$col(class = "c-chip"), tags$col(class = "c-btn"),
                       tags$col(class = "c-chip"), tags$col(class = "c-btn")),
         tags$thead(tags$tr(tags$th("Part"), tags$th(colspan = 2, "Part status"), tags$th(colspan = 2, "Feedback"))),
         lapply(names(def$sections), function(sid) uiOutput(paste0("step_", sid), container = tags$tbody))),
       uiOutput("notices")),
  card(card_header("Progress"), tags$p(class = "text-muted small mb-1",
       "Who has the workshop open now, and per part how many questions they answered. Grey: not open yet. Green: all answered."),
       uiOutput("progress")),
  card(card_header("Answers"), {
    parts <- Filter(function(sec) length(ws_section_questions(def, sec$id)) > 0, def$sections)
    do.call(navset_underline, c(unname(lapply(parts, function(sec) nav_panel(sec$title,
      lapply(names(ws_section_questions(def, sec$id)), function(qid) uiOutput(paste0("sum_", qid)))))),
      list(id = "answer_tab")))
  })
)

server <- function(input, output, session) {
  # The page's data. Checked every REFRESH_MS, but only replaced when something changed. A click updates it at once.
  current <- reactiveVal(first)
  fingerprint <- reactiveVal(rlang::hash(first))
  refresh <- function() {
    o <- overview()
    h <- rlang::hash(o)
    if (!identical(h, isolate(fingerprint()))) { fingerprint(h); current(o) }
  }
  observe({ invalidateLater(REFRESH_MS); refresh() })

  # show(id, ui): put ui in output `id`, and redraw it only if it differs from what is there. (Redrawing every part
  # of the page whenever anything changed made it flash.) A reactiveVal does not invalidate on an identical value.
  pieces <- list()
  show <- function(id, ui) {
    if (is.null(pieces[[id]])) {
      rv <- reactiveVal(ui); pieces[[id]] <<- rv
      output[[id]] <- renderUI(rv())
    } else pieces[[id]](ui)
  }

  observeEvent(input$release, {
    r <- input$release
    allowed <- c(unlist(lapply(names(def$sections), function(s) c(section_keys(s, "open"), section_keys(s, "feedback")))),
                 NOTICES_OFF)
    keys <- intersect(unlist(r$keys), allowed)
    if (length(keys)) api("POST", "admin/release", list(keys = as.list(keys), target = r$target, on = isTRUE(r$on)))
    refresh()
  })

  observe({
    s <- current()
    gated <- Filter(function(x) isTRUE(x$gated), def$sections)
    fb_keys <- unlist(lapply(names(def$sections), section_keys, part = "feedback"))
    show("n_participants", length(s$pids))
    show("n_online", sum(s$online))
    show("n_open", sprintf("%d of %d", sum(paste0("open:", names(gated)) %in% s$rel$key[s$rel$target == ALL]), length(gated)))
    show("n_feedback", sprintf("%d of %d", sum(fb_keys %in% s$rel$key[s$rel$target == ALL]), length(fb_keys)))

    for (sec in def$sections) show(paste0("step_", sec$id), step_row(sec, s$rel))
    show("notices", notices_ui(s$rel))

    # The progress grid: its frame changes only when participants are added; each row is its own output.
    show("progress", if (!length(s$pids)) tags$p(class = "text-muted", "No participants yet.") else
      tags$table(class = "table table-sm ws-grid",
        tags$thead(tags$tr(tags$th("Participant"), tags$th("Online"), lapply(def$sections, function(sec)
          tags$th(sub("^([0-9]+)\\..*", "\\1", sec$title), title = sec$title)))),
        lapply(s$pids, function(p) uiOutput(paste0("prow_", p), container = tags$tbody))))
    for (p in s$pids) show(paste0("prow_", p), progress_row(p, s))

    for (q in def$questions) show(paste0("sum_", q$id), summary_ui(q, s$answers, length(s$pids)))
  })

  observeEvent(input$present, {
    showModal(modalDialog(uiOutput("present_body"), size = "xl", easyClose = TRUE, footer = modalButton("Close")))
  })
  output$present_body <- renderUI({
    req(input$present)
    s <- current()
    summary_ui(def$questions[[input$present]], s$answers, length(s$pids), big = TRUE)
  })
}

shinyApp(ui, server)
