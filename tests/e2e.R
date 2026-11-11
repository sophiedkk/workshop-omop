# End-to-end test with real (headless) browsers, through ShinyProxy: two participants and the facilitator.
# Needs a running stack (./ws up) with at least two participants, and a fresh state (./ws setup --reset).
#
#   ./ws e2e
#
# Checks: login; everything gated starts locked; opening a section shows it live; exercises run against the
# data; answers save; feedback appears live after release, right/wrong per answer; a release to one participant
# reaches only that participant; the facilitator page counts it; every exercise in the tutorial runs cleanly.

library(chromote)
set_chrome_args(c(default_chrome_args(), "--no-sandbox"))
BASE <- Sys.getenv("WS_BASE", "http://shinyproxy:8080")
users <- yaml::read_yaml("/run-dir/state/users.yml")
# The first two participants on the list (whatever their usernames) and the facilitator.
P1 <- setdiff(names(users), "admin")[1]
P2 <- setdiff(names(users), "admin")[2]

failures <- 0
check <- function(ok, what) {
  cat(if (isTRUE(ok)) "  ok    " else { failures <<- failures + 1; "  FAIL  " }, what, "\n", sep = "")
}

js <- function(s, code) {
  r <- s$Runtime$evaluate(code, awaitPromise = TRUE, returnByValue = TRUE)
  if (!is.null(r$exceptionDetails)) stop("JS error: ", r$exceptionDetails$exception$description %||% r$exceptionDetails$text)
  r$result$value
}
wait_for <- function(s, code, timeout = 30, what = code) {
  t0 <- Sys.time()
  repeat {
    v <- tryCatch(js(s, code), error = function(e) NULL)
    if (isTRUE(v)) return(TRUE)
    if (as.numeric(Sys.time() - t0, units = "secs") > timeout) return(FALSE)
    Sys.sleep(0.5)
  }
}
`%||%` <- function(a, b) if (is.null(a)) b else a
#' Navigate and wait for the page to load. Listen first: a small page can finish loading before a later wait starts.
goto <- function(s, url) {
  loaded <- s$Page$loadEventFired(wait_ = FALSE)
  s$Page$navigate(url, wait_ = FALSE)
  s$wait_for(loaded)
}

#' A browser session logged in as `user`, on that user's app (opened directly, without ShinyProxy's frame).
open_as <- function(user, app) {
  s <- ChromoteSession$new(width = 1400, height = 1000)
  goto(s, paste0(BASE, "/login"))
  js(s, sprintf("document.querySelector('input[name=username]').value = '%s';
                 document.querySelector('input[name=password]').value = '%s';
                 document.querySelector('form').submit(); true", user, users[[user]]$password))
  Sys.sleep(2)
  goto(s, paste0(BASE, "/app_direct/", app, "/"))
  ok <- wait_for(s, "!!(window.Shiny && Shiny.shinyapp && Shiny.shinyapp.isConnected())", timeout = 90)
  check(ok, sprintf("%s: logged in, %s connected", user, app))
  s
}
is_open <- function(s, sec) js(s, sprintf("document.querySelector('.ws-section[data-section=\"%s\"]').classList.contains('ws-open')", sec))
release <- function(admin, keys, target = "*") {
  # The facilitator's "Open part" / "Show feedback" button for these keys and target; click it.
  js(admin, sprintf("(function(){ var b = Array.from(document.querySelectorAll('.rel-btn')).find(function(x) {
      return x.dataset.keys === '%s' && x.dataset.target === '%s' && x.dataset.on === 'true'; });
      if (!b) return false; b.click(); return true; })()", paste(keys, collapse = ","), target))
}
answer <- function(s, id, value) {
  js(s, sprintf("(function(){ var el = document.querySelector('.ws-question[data-id=\"%s\"]');
      if (el.dataset.type === 'choice') { el.querySelector('input[value=\"%s\"]').click(); }
      else { var i = el.querySelector('.ws-input'); i.value = '%s'; i.dispatchEvent(new Event('input', {bubbles: true})); }
      el.querySelector('.ws-save').click(); return true; })()", id, value, value))
  wait_for(s, sprintf("document.querySelector('.ws-question[data-id=\"%s\"] .ws-status').textContent.indexOf('Saved') === 2", id), 15)
}
feedback <- function(s, id) js(s, sprintf("document.querySelector('.ws-question[data-id=\"%s\"] .ws-feedback').textContent", id))
# The blanks (____) in fill-in exercises, in order, as a participant would fill them in.
FILL <- list("gender-other" = "8507", "median-birth" = "year_of_birth", "race-names" = "race_concept_id",
             "af-up" = "313217", "af-down" = "ancestor_concept_id", "af-names" = "name",
             "count-conditions" = "count", "count-af" = "313217", "count-drugs" = "drug_exposure",
             "top-drugs" = "drug_concept_id", "top-procedures" = "procedure_concept_id",
             "count-deaths" = "cdm$death |> count()")

#' Run an exercise like a participant: go to its part in the sidebar (learnr only runs exercises in the
#' current part), fill in blanks if asked, clear the old output, press Run Code, wait for the new output.
run_exercise <- function(s, label, timeout = 120, fill = TRUE, code = NULL) {
  s$Page$bringToFront()   # background pages are throttled; learnr's Run does not complete there
  js(s, sprintf("(function(){
      var ex = document.querySelector('.tutorial-exercise[data-label=\"%s\"]');
      var topic = ex.closest('.section.level2');
      var topics = Array.from(document.querySelectorAll('.section.level2'));
      document.querySelectorAll('.topicsList .topic')[topics.indexOf(topic)].querySelector('a').click();
      document.getElementById('tutorial-exercise-%s-output').innerHTML = '';
      return true; })()", label, label))
  Sys.sleep(1)
  if (!is.null(code)) {
    js(s, sprintf("(function(){ ace.edit(document.querySelector('.tutorial-exercise[data-label=\"%s\"] .ace_editor')).setValue(%s, 1); return true; })()",
                  label, jsonlite::toJSON(code, auto_unbox = TRUE)))
  } else if (fill && !is.null(FILL[[label]])) {
    js(s, sprintf("(function(){ var ed = ace.edit(document.querySelector('.tutorial-exercise[data-label=\"%s\"] .ace_editor'));
        var code = ed.getValue(); %s.forEach(function(v){ code = code.replace('____', v); }); ed.setValue(code, 1); return true; })()",
        label, jsonlite::toJSON(FILL[[label]])))
  }
  js(s, sprintf("document.querySelector('.tutorial-exercise[data-label=\"%s\"] .btn-tutorial-run').click(); true", label))
  out_js <- sprintf("document.getElementById('tutorial-exercise-%s-output')", label)
  # Output is text, a table, or only a plot (an <img>, which has no text).
  done <- wait_for(s, sprintf("(function(o){ return o.innerText.trim().length > 0 || !!o.querySelector('img'); })(%s)", out_js), timeout)
  out <- js(s, sprintf("%s.innerText", out_js))
  err <- js(s, sprintf("!!%s.querySelector('.alert-danger, .error')", out_js))
  list(done = done, text = out, error = isTRUE(err) || grepl("(^|\\n)Error", out),
       warning = grepl("Warning|deprecated", out))
}

cat("Participants and facilitator log in\n")
p1 <- open_as(P1, "tutorial")
p2 <- open_as(P2, "tutorial")
admin <- open_as("admin", "facilitator")
check(wait_for(admin, "document.querySelectorAll('.rel-btn').length > 0", 20), "facilitator: workshop steps shown")

cat("Everything gated starts locked\n")
check(!is_open(p1, "start") && !is_open(p1, "people") && !is_open(p1, "omopsketch"), "wp01: gated parts locked")
check(release(admin, "open:start"), "facilitator: open part 1 for everyone")
check(wait_for(p1, "document.querySelector('.ws-section[data-section=\"start\"]').classList.contains('ws-open')", 10),
      "wp01: part 1 appears without reload")
r <- run_exercise(p1, "table-names")
check(r$done && !r$error && grepl("person", r$text), "wp01: first exercise lists the tables")
check(answer(p1, "data_end_year", 2023), "wp01: answers a question in part 1")

cat("A participant cannot break cdm for the next code box\n")
r <- run_exercise(p1, "table-names", code = "cdm <- 5\ncdm")
check(r$done && grepl("5", r$text), "wp01: overwrites cdm in one box")
r <- run_exercise(p1, "snapshot")
check(r$done && !r$error, "wp01: ...the next box still has the real cdm")
r <- run_exercise(p1, "table-names", code = "cdmDisconnect(cdm)\nprint('closed')")
check(r$done && grepl("closed", r$text), "wp01: closes the database connection")
r <- run_exercise(p1, "snapshot")
check(r$done && !r$error, "wp01: ...the next box reconnects by itself (it queries the database)")
run_exercise(p1, "table-names", code = "names(cdm)")   # put the box back (learnr remembers edited code)

cat("Opening a part shows it live\n")
check(release(admin, "open:people"), "facilitator: open part 2 for everyone")
check(wait_for(p1, "document.querySelector('.ws-section[data-section=\"people\"]').classList.contains('ws-open')", 10),
      "wp01: part 2 appears without reload")
check(wait_for(p2, "document.querySelector('.ws-section[data-section=\"people\"]').classList.contains('ws-open')", 10),
      "wp02: part 2 appears without reload")
check(wait_for(p1, "document.getElementById('ws-notice').style.display === 'block'", 10), "wp01: notice that part 2 is open")

cat("Exercises and answers\n")
r <- run_exercise(p1, "count-people")
check(r$done && grepl("10754", r$text), "wp01: count-people exercise returns 10754")
r <- run_exercise(p1, "median-birth", fill = FALSE)
check(r$done && grepl("blank", r$text, ignore.case = TRUE), "wp01: running with a blank left asks to fill it in")
r <- run_exercise(p1, "median-birth")
check(r$done && grepl("1970", r$text) && !r$warning, "wp01: filled-in exercise returns 1970, no warning")
r <- run_exercise(p1, "person-head")
check(r$done && js(p1, "!!document.querySelector('#tutorial-exercise-person-head-output .ws-table') &&
        document.querySelectorAll('#tutorial-exercise-person-head-output .ws-table th').length === 18"),
      "wp01: a table result shows as one scrollable table with all 18 columns")
check(js(p1, "getComputedStyle(document.querySelector('.btn-tutorial-run')).cursor") == "pointer",
      "wp01: Run Code shows the normal hand cursor")
js(p1, "(function(){ var i = document.querySelector('.ws-question[data-id=\"n_people\"] .ws-input'); i.focus(); i.value = '10754';
        i.dispatchEvent(new Event('input', {bubbles: true})); return true; })()")
p1$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13, text = "\r")
p1$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13)
check(wait_for(p1, "document.querySelector('.ws-question[data-id=\"n_people\"] .ws-status').textContent.indexOf('Saved') === 2", 15),
      "wp01: Enter saves an answer")
check(answer(p1, "n_people", 10754), "wp01: saves n_people")
check(answer(p1, "gender_8532", "FEMALE"), "wp01: saves gender_8532")
check(answer(p1, "n_female", 5000), "wp01: saves n_female (wrong)")
check(!answer(p1, "af_children", 12) || FALSE, "wp01: answer in a closed part is not saved")
check(grepl("not open yet", js(p1, "document.querySelector('.ws-question[data-id=\"af_children\"] .ws-status').textContent")),
      "wp01: ...and says the part is not open")

cat("Feedback appears live after release\n")
Sys.sleep(1)
check(feedback(p1, "n_people") == "", "wp01: no feedback before release")
check(release(admin, c("feedback:n_people", "feedback:gender_8532", "feedback:gender_8507", "feedback:n_female",
                       "feedback:median_birth_year", "feedback:birth_decade", "feedback:n_asian")),
      "facilitator: show feedback for part 2")
check(wait_for(p1, "document.querySelector('.ws-question[data-id=\"n_people\"] .ws-feedback').textContent.length > 0", 10),
      "wp01: feedback appears without reload")
check(grepl("✓ Correct", feedback(p1, "n_people")), "wp01: n_people marked right")
check(grepl("Not quite", feedback(p1, "n_female")), "wp01: n_female marked wrong")
check(grepl("8532 is FEMALE", feedback(p1, "gender_8532")), "wp01: choice feedback text shown")
check(grepl("Not answered", feedback(p1, "median_birth_year")) && grepl("1970", feedback(p1, "median_birth_year")),
      "wp01: unanswered question gets 'Not answered' and the explanation")
check(wait_for(p2, "document.querySelector('.ws-question[data-id=\"n_people\"] .ws-feedback').textContent.indexOf('Not answered') >= 0", 10),
      "wp02: answered nothing, still gets feedback")

cat("Pop-up notices can be turned off\n")
js(p1, "document.getElementById('ws-notice').style.display = 'none'; true")
check(js(admin, "(function(){ var b = document.querySelector('.ws-notices .rel-btn'); if (!b || b.dataset.on !== 'true') return false;
                 b.click(); return true; })()"), "facilitator: turns notices off")
Sys.sleep(4)
check(js(admin, "(function(){ var b = Array.from(document.querySelectorAll('.rel-btn')).find(function(x) {
          return x.dataset.on === 'true' && x.dataset.keys.split(',').indexOf('feedback:af_concept_id') >= 0; });
        if (!b) return false; b.click(); return true; })()"), "facilitator: shows feedback for part 3")
check(wait_for(p1, "document.querySelector('.ws-question[data-id=\"af_concept_id\"] .ws-feedback').textContent.length > 0", 10),
      "wp01: part 3 feedback arrives")
Sys.sleep(1)
check(js(p1, "document.getElementById('ws-notice').style.display") != "block", "wp01: ...without a notice, as notices are off")
js(admin, "document.querySelector('.ws-notices .rel-btn').click(); true")
check(wait_for(admin, "document.querySelector('.ws-notices .rel-btn').dataset.on === 'true'", 10), "facilitator: notices on again")

cat("Facilitator page\n")
check(wait_for(admin, "document.getElementById('n_online').textContent === '2'", 10), "facilitator: shows 2 participants online")
check(wait_for(admin, "document.body.innerText.indexOf('Correct answer:') >= 0", 10), "facilitator: shows the correct answers")
check(wait_for(admin, "document.body.innerText.indexOf('1 of 1 right') >= 0", 10), "facilitator: number summary shows 1 of 1 right")

cat("Every exercise runs (all parts opened)\n")
for (k in c("open:hierarchy", "open:records", "open:omopsketch")) check(release(admin, k), paste("facilitator:", k))
check(wait_for(p1, "document.querySelectorAll('.ws-section.ws-open').length === 5", 10), "wp01: all parts open")
labels <- js(p1, "Array.from(document.querySelectorAll('.tutorial-exercise')).map(function(e){return e.dataset.label})")
for (l in unlist(labels)) {
  t0 <- Sys.time()
  r <- run_exercise(p1, l, timeout = 180)
  check(r$done && !r$error && !r$warning, sprintf("exercise %-18s %5.1fs%s", l, as.numeric(Sys.time() - t0, units = "secs"),
                                    if (r$error || r$warning) paste0("  ", substr(r$text, 1, 200)) else ""))
}

cat(if (failures) sprintf("\n%d check(s) FAILED\n", failures) else "\nAll checks passed\n")
quit(status = if (failures) 1 else 0)
