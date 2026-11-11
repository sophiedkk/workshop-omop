source(file.path(Sys.getenv("WS_HOME", "../.."), "app", "core.R"))

ws_dir <- file.path(Sys.getenv("WS_HOME", "../.."), "workshops", "omop_explore")

fixture <- function() {
  def <- ws_definition(file.path(ws_dir, "questions.yml"))
  key <- ws_key(file.path(ws_dir, "key.yml"), def)
  con <- ws_db(tempfile(fileext = ".sqlite"))
  ws_add_participant(con, "alice", "tok-alice")
  ws_add_participant(con, "bob", "tok-bob")
  list(def = def, key = key, con = con)
}

test_that("the omop_explore definition and key load and agree", {
  f <- fixture()
  expect_setequal(names(f$def$sections), c("start", "people", "hierarchy", "records", "omopsketch"))
  expect_true(f$def$sections$start$gated)
  expect_true(f$def$sections$people$gated)
  expect_true(all(names(f$key) %in% names(f$def$questions)))
})

test_that("a key that does not match the questions is refused", {
  def <- ws_definition(file.path(ws_dir, "questions.yml"))
  bad <- tempfile(fileext = ".yml")
  yaml::write_yaml(list(nope = list(expected = 1),
                        hierarchy_table = list(options = list(concept = list("right", "x")))), bad)
  expect_error(ws_key(bad, def), "not a question")
  expect_error(ws_key(bad, def), "differ from the question")
})

test_that("tokens identify participants; unknown tokens do not", {
  f <- fixture()
  expect_equal(ws_participant_for(f$con, "tok-alice"), "alice")
  expect_null(ws_participant_for(f$con, "wrong"))
  expect_null(ws_participant_for(f$con, ""))
  expect_false(any(DBI::dbGetQuery(f$con, "SELECT token_hash FROM participants")$token_hash == "tok-alice"))
})

test_that("everything gated starts locked; answers are refused until the section is open", {
  f <- fixture()
  me <- ws_me(f$con, f$def, f$key, "alice")
  expect_length(unlist(me$open), 0)
  out <- ws_save_answer(f$con, f$def, "alice", "n_people", 10754)
  expect_equal(out$status, 403L)
  ws_set_release(f$con, "open:people", ALL, TRUE)
  expect_equal(ws_save_answer(f$con, f$def, "alice", "n_people", 10754)$status, 200L)
  ws_set_release(f$con, "open:people", ALL, FALSE)
  expect_equal(ws_save_answer(f$con, f$def, "alice", "n_people", 1)$status, 403L)
  expect_equal(ws_answers(f$con, "alice")$value[[1]], 10754)   # closing keeps saved answers
})

test_that("a section opened for one participant stays closed for the others", {
  f <- fixture()
  ws_set_release(f$con, "open:people", "alice", TRUE)
  expect_equal(ws_save_answer(f$con, f$def, "alice", "n_female", 5165)$status, 200L)
  expect_equal(ws_save_answer(f$con, f$def, "bob", "n_female", 5165)$status, 403L)
})

test_that("answers are validated per type; last save wins", {
  f <- fixture()
  ws_set_release(f$con, c("open:people", "open:hierarchy", "open:omopsketch"), ALL, TRUE)
  expect_equal(ws_save_answer(f$con, f$def, "alice", "n_people", "many")$status, 400L)
  expect_equal(ws_save_answer(f$con, f$def, "alice", "n_people", NA_real_)$status, 400L)
  expect_equal(ws_save_answer(f$con, f$def, "alice", "hierarchy_table", "not an option")$status, 400L)
  text_q <- list(id = "t", type = "text")   # this workshop has no text questions; the rules still apply
  expect_match(ws_check_value(text_q, "   ")$error, "Fill in")
  expect_match(ws_check_value(text_q, strrep("x", 6000))$error, "too long")
  expect_equal(ws_check_value(text_q, "  fine  ")$value, "fine")
  expect_equal(ws_save_answer(f$con, f$def, "alice", "nope", 1)$status, 404L)
  ws_save_answer(f$con, f$def, "alice", "hierarchy_table", "concept")
  ws_save_answer(f$con, f$def, "alice", "hierarchy_table", "concept_ancestor")
  a <- ws_answers(f$con, "alice")
  expect_equal(a$value[a$question == "hierarchy_table"][[1]], "concept_ancestor")
})

test_that("feedback appears only after release, judged per participant's own answer", {
  f <- fixture()
  ws_set_release(f$con, c("open:people", "open:hierarchy"), ALL, TRUE)
  ws_save_answer(f$con, f$def, "alice", "n_people", 10754)
  ws_save_answer(f$con, f$def, "alice", "n_female", 5000)
  ws_save_answer(f$con, f$def, "alice", "hierarchy_table", "concept")
  expect_length(ws_me(f$con, f$def, f$key, "alice")$feedback, 0)

  ws_set_release(f$con, c("feedback:n_people", "feedback:n_female", "feedback:hierarchy_table"), ALL, TRUE)
  fb <- ws_me(f$con, f$def, f$key, "alice")$feedback
  expect_true(fb$n_people$ok)
  expect_false(fb$n_female$ok)
  expect_false(fb$hierarchy_table$ok)
  expect_match(fb$hierarchy_table$text, "not how they relate")
  expect_match(fb$n_people$explain, "10,754")
})

test_that("released feedback also reaches participants who did not answer", {
  f <- fixture()
  ws_set_release(f$con, c("open:people", "feedback:n_people"), ALL, TRUE)
  fb <- ws_me(f$con, f$def, f$key, "bob")$feedback
  expect_true(isTRUE(fb$n_people$unanswered))
  expect_true(is.na(fb$n_people$ok))
  expect_match(fb$n_people$explain, "10,754")
  expect_null(fb$n_female)                       # not released
})

test_that("feedback released to one participant is not shown to another", {
  f <- fixture()
  ws_set_release(f$con, "open:people", ALL, TRUE)
  for (p in c("alice", "bob")) ws_save_answer(f$con, f$def, p, "n_people", 10754)
  ws_set_release(f$con, "feedback:n_people", "bob", TRUE)
  expect_length(ws_me(f$con, f$def, f$key, "alice")$feedback, 0)
  expect_true(ws_me(f$con, f$def, f$key, "bob")$feedback$n_people$ok)
})

test_that("a participant's view never contains key content that is not released", {
  f <- fixture()
  ws_set_release(f$con, c("open:people", "open:omopsketch"), ALL, TRUE)
  ws_save_answer(f$con, f$def, "alice", "obs_per_person", "It varies a lot")
  json <- jsonlite::toJSON(ws_me(f$con, f$def, f$key, "alice"), auto_unbox = TRUE)
  for (k in f$key) {
    texts <- c(k$ok, k$bad, k$explain, unlist(lapply(k$options, `[[`, 2)), as.character(k$expected))
    for (t in texts) expect_false(grepl(t, json, fixed = TRUE), info = t)
  }
})

test_that("the facilitator can only set known release keys for known targets", {
  f <- fixture()
  expect_equal(ws_release(f$con, f$def, f$key, "open:people", ALL, TRUE)$status, 200L)
  expect_equal(ws_release(f$con, f$def, f$key, "open:nope", ALL, TRUE)$status, 400L)        # no such part
  expect_equal(ws_release(f$con, f$def, f$key, "feedback:nope", ALL, TRUE)$status, 400L)       # unknown question
  expect_equal(ws_release(f$con, f$def, f$key, "open:people", "mallory", TRUE)$status, 400L)
  expect_equal(ws_release(f$con, f$def, f$key, list(), ALL, TRUE)$status, 400L)
  expect_true("open:people" %in% ws_released(f$con, "bob"))
})

test_that("admin tokens are separate from participant tokens", {
  f <- fixture()
  ws_add_admin(f$con, "tok-admin")
  expect_true(ws_is_admin(f$con, "tok-admin"))
  expect_false(ws_is_admin(f$con, "tok-alice"))
  expect_null(ws_participant_for(f$con, "tok-admin"))
  expect_false(ws_is_admin(f$con, ""))
})

test_that("a participant whose page asks for its state counts as online", {
  f <- fixture()
  p <- ws_presence(f$con)
  expect_false(any(p$online))
  ws_me(f$con, f$def, f$key, "alice")
  p <- ws_presence(f$con)
  expect_true(p$online[p$id == "alice"])
  expect_false(p$online[p$id == "bob"])
})

test_that("the facilitator can turn participants' pop-up notices off and on again", {
  f <- fixture()
  expect_true(ws_me(f$con, f$def, f$key, "alice")$notices)
  expect_equal(ws_release(f$con, f$def, f$key, NOTICES_OFF, ALL, TRUE)$status, 200L)
  expect_false(ws_me(f$con, f$def, f$key, "alice")$notices)
  expect_equal(ws_release(f$con, f$def, f$key, NOTICES_OFF, ALL, FALSE)$status, 200L)
  expect_true(ws_me(f$con, f$def, f$key, "alice")$notices)
})
