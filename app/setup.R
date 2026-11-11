# Set up a workshop run: participants, their passwords and tokens, the admin, the state database and the
# ShinyProxy configuration. Run it through compose (see README):
#
#   ./ws setup                 participants from config.yml (names), else wp01..wp15;
#                              or for testing: --participants 20 (wp01..wp20), or --ids ana,ben,...
#   ./ws setup --add           add the people in config.yml who have no account yet; everyone else keeps theirs
#   ./ws setup --add "Ana de Vries"   (or "Ana de Vries: ana") add one person, also when not in config.yml
#   ./ws setup --reset         keep participants and passwords; clear answers and releases (backup first)
#   ./ws setup --fresh         move everything to run/backups/<time>/ and start over (new passwords)
#   ./ws setup --config        only rewrite shinyproxy/application.yml (after changing limits or the image)
#
# Inside the container the run folder is /run-dir. WS_HOST_RUN is the same folder's path on the host: ShinyProxy
# asks the container engine to mount per-participant folders by host path.

source(file.path(Sys.getenv("WS_HOME", "/srv/workshop"), "app", "core.R"))

args <- commandArgs(trailingOnly = TRUE)
flag <- function(name) name %in% args
value <- function(name, default = NULL) { i <- match(name, args); if (is.na(i) || i == length(args)) default else args[i + 1] }

RUN <- "/run-dir"
HOST_RUN <- Sys.getenv("WS_HOST_RUN")
WORKSHOP <- Sys.getenv("WS_WORKSHOP_ID", "omop_explore")
IMAGE <- Sys.getenv("WS_IMAGE", "localhost/rworkshop:latest")
if (!nzchar(HOST_RUN)) stop("WS_HOST_RUN is not set (the run folder's path on the host). Use ./ws setup.", call. = FALSE)
def <- ws_definition(file.path("/srv/workshop/workshops", WORKSHOP, "questions.yml"))

p <- function(...) file.path(RUN, ...)
stamp <- format(Sys.time(), "%Y%m%d-%H%M%S")
secret <- function(n = 32) paste(as.character(openssl::rand_bytes(n)), collapse = "")
# Passwords people can type: no 0/O, 1/l/I.
password <- function() paste(sample(strsplit("abcdefghijkmnpqrstuvwxyz23456789", "")[[1]], 10, replace = TRUE), collapse = "")
write_secret <- function(path, text, mode = "600") {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  writeLines(text, path)
  Sys.chmod(path, mode)
}

# ---------------------------------------------------------------- --fresh / --reset

if (flag("--fresh")) {
  moved <- intersect(c("state", "tokens", "handouts", "shinyproxy"), list.files(RUN))
  if (length(moved)) {
    dest <- p("backups", stamp); dir.create(dest, recursive = TRUE)
    for (m in moved) file.rename(p(m), file.path(dest, m))
    message("Moved ", toString(moved), " to run/backups/", stamp, "/")
  }
}

db_file <- p("state", "state.sqlite")
if (flag("--reset")) {
  if (!file.exists(db_file)) stop("Nothing to reset: no state yet. Run ./ws setup first.", call. = FALSE)
  dir.create(p("backups"), showWarnings = FALSE)
  con <- ws_db(db_file)
  DBI::dbExecute(con, sprintf("VACUUM INTO '%s'", p("backups", paste0(stamp, "-reset.sqlite"))))
  DBI::dbExecute(con, "DELETE FROM answers"); DBI::dbExecute(con, "DELETE FROM releases")
  message("Cleared answers and releases (backup: run/backups/", stamp, "-reset.sqlite). Participants and passwords kept.")
  quit(save = "no")
}

# ---------------------------------------------------------------- participants

users_file <- p("state", "users.yml")   # who exists, their names and passwords (ShinyProxy needs them in plain text)
PUBLIC_URL <- Sys.getenv("WS_PUBLIC_URL", "http://127.0.0.1:8080")

#' A username from a full name: lower case, ASCII, words joined with "-" ("Ana de Vries" -> "ana-de-vries").
username_for <- function(name) {
  u <- tolower(iconv(name, to = "ASCII//TRANSLIT"))
  u <- gsub("[^a-z0-9]+", "-", u)
  u <- gsub("^-+|-+$", "", u)
  if (!grepl("^[a-z]", u)) u <- paste0("p-", u)
  substr(u, 1, 31)
}

#' The participants: list(username = full name), from --ids, --participants N, config.yml, or wp01..wp15.
participant_list <- function() {
  if (!is.null(value("--ids"))) { ids <- trimws(strsplit(value("--ids"), ",")[[1]]); return(stats::setNames(as.list(ids), ids)) }
  if (!is.null(value("--participants"))) { ids <- sprintf("wp%02d", seq_len(as.integer(value("--participants")))); return(stats::setNames(as.list(ids), ids)) }
  cfg_file <- p("config.yml")
  entries <- if (file.exists(cfg_file)) yaml::read_yaml(cfg_file)$participants else NULL
  if (is.null(entries)) { ids <- sprintf("wp%02d", 1:15); return(stats::setNames(as.list(ids), ids)) }
  out <- list()
  for (e in entries) {
    # "- Ana de Vries" (a name) or "- Ana de Vries: ana" (a name with a chosen username)
    if (is.list(e)) { name <- names(e)[1]; id <- as.character(e[[1]]) } else { name <- as.character(e); id <- username_for(name) }
    name <- trimws(name); id <- trimws(id)
    if (id %in% names(out)) {   # two people with the same name: ana-de-vries, ana-de-vries-2, ...
      k <- 2; while (paste0(id, "-", k) %in% names(out)) k <- k + 1; id <- paste0(id, "-", k)
    }
    out[[id]] <- name
  }
  out
}

check_ids <- function(ids) {
  bad <- ids[!grepl("^[a-z][a-z0-9_-]{0,30}$", ids)]
  if (length(bad)) stop("Usernames must be lower case letters, digits, _ or - (and start with a letter): ", toString(bad), call. = FALSE)
  if ("admin" %in% ids) stop("'admin' is reserved for the facilitator.", call. = FALSE)
}

#' Give each of `people` (list(username = full name)) an account: a token, a row in the state database, a password.
add_people <- function(con, users, people) {
  for (id in names(people)) {
    token <- secret()
    ws_add_participant(con, id, token, name = people[[id]])
    write_secret(p("tokens", id, "token"), token, mode = "644")   # read by that participant's container only
    users[[id]] <- list(name = people[[id]], password = password(), group = "participants")
  }
  Sys.chmod(list.dirs(p("tokens")), "755")
  users
}

if (flag("--add")) {
  if (!file.exists(users_file)) stop("No participants yet: run ./ws setup first (it creates everyone in config.yml).", call. = FALSE)
  users <- yaml::read_yaml(users_file)
  one <- value("--add")
  if (!is.null(one) && !startsWith(one, "--")) {
    # One person: "Ana de Vries" or "Ana de Vries: ana".
    parts <- trimws(strsplit(one, ":", fixed = TRUE)[[1]])
    name <- parts[1]; id <- if (length(parts) > 1) parts[2] else username_for(name)
    if (id %in% names(users)) stop(sprintf("The username '%s' already exists. Choose another: --add \"%s: <username>\"", id, name), call. = FALSE)
    people <- stats::setNames(list(name), id)
  } else {
    # Everyone in config.yml who has no account yet.
    people <- participant_list()
    people <- people[setdiff(names(people), names(users))]
    if (!length(people)) {
      message("Everyone in config.yml already has an account; nothing to add.")
      quit(save = "no")
    }
  }
  check_ids(names(people))
  con <- ws_db(db_file)
  users <- add_people(con, users, people)
  write_secret(users_file, yaml::as.yaml(users))
  message(sprintf("Added %d participant(s); everyone else keeps their account and answers:\n  %s", length(people),
                  paste(sprintf("%-28s %s", names(people), unlist(people)), collapse = "\n  ")))
} else if (!file.exists(users_file)) {
  if (flag("--config")) stop("No participants yet. Run ./ws setup first.", call. = FALSE)
  people <- participant_list()
  ids <- names(people)
  if (!length(ids)) stop("No participants: the list in config.yml is empty.", call. = FALSE)
  check_ids(ids)

  dir.create(p("state"), recursive = TRUE, showWarnings = FALSE); Sys.chmod(p("state"), "700")
  con <- ws_db(db_file)
  users <- add_people(con, list(), people)
  admin_token <- secret()
  ws_add_admin(con, admin_token)
  write_secret(p("tokens", "admin", "token"), admin_token, mode = "644")
  users[["admin"]] <- list(name = "Facilitator", password = password(), group = "admin")
  write_secret(users_file, yaml::as.yaml(users))
  Sys.chmod(list.dirs(p("tokens")), "755")
  message(sprintf("Created %d participants and the admin:\n  %s", length(ids),
                  paste(sprintf("%-28s %s", ids, unlist(people)), collapse = "\n  ")))
} else if (!flag("--config")) {
  message("Participants already exist (run/state/users.yml); keeping them. Use --fresh to start over (new list from",
          " config.yml, new passwords), --add to add people, or --reset to clear answers.")
}

# ---------------------------------------------------------------- login cards
# Written every time, so they always show the current address.
users <- yaml::read_yaml(users_file)
esc <- function(x) gsub("<", "&lt;", gsub("&", "&amp;", x, fixed = TRUE), fixed = TRUE)
dir.create(p("handouts"), showWarnings = FALSE); Sys.chmod(p("handouts"), "700")
for (id in names(users)) {
  write_secret(p("handouts", paste0(id, ".txt")), sprintf("%s\n\nName:     %s\nGo to:    %s\nUsername: %s\nPassword: %s",
                                                           def$title, users[[id]]$name %||% id, PUBLIC_URL, id, users[[id]]$password))
}
card <- function(id) sprintf(
  '<div class="card"><div class="title">%s</div><div class="name">%s</div><table><tr><th>Go to</th><td>%s</td></tr><tr><th>Username</th><td><b>%s</b></td></tr><tr><th>Password</th><td><b>%s</b></td></tr></table></div>',
  esc(def$title), esc(users[[id]]$name %||% id), esc(PUBLIC_URL), esc(id), esc(users[[id]]$password))
participants <- setdiff(names(users), "admin")
write_secret(p("handouts", "all.html"), c(
  "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Login cards</title><style>",
  "body { font-family: system-ui, sans-serif; margin: 12mm; } h1 { font-size: 16px; color: #5F6155; }",
  ".grid { display: grid; grid-template-columns: 1fr 1fr; gap: 6mm; }",
  ".card { border: 1px solid #C4C6B1; border-top: 5px solid #EE7F00; border-radius: 6px; padding: 5mm 6mm; break-inside: avoid; }",
  ".title { font-size: 12px; color: #5F6155; } .name { font-size: 20px; font-weight: 700; margin: 2mm 0 3mm; }",
  "th { text-align: left; font-weight: 400; color: #5F6155; padding: 1mm 5mm 1mm 0; } td { font-family: ui-monospace, monospace; font-size: 15px; }",
  "@media print { h1 { display: none; } body { margin: 8mm; } }",
  "</style></head><body>",
  sprintf("<h1>%d login cards: print and cut. The facilitator's login is in admin.txt (not on this sheet).</h1>", length(participants)),
  "<div class='grid'>", vapply(participants, card, ""), "</div></body></html>"))
# With Docker (containers run as the real root), hand the login cards to the user who ran ./ws setup.
owner <- Sys.getenv("WS_OWNER")
if (grepl("^[0-9]+:[0-9]+$", owner)) {
  system2("chown", c("-R", owner, shQuote(p("handouts"))))
}
message("Login cards: run/handouts/all.html (print it), one text file per person in run/handouts/. Address: ", PUBLIC_URL)

# ---------------------------------------------------------------- ShinyProxy configuration

host <- function(...) file.path(HOST_RUN, ...)
mount <- function(src, dst, mode = "ro") sprintf("%s:%s:%s", src, dst, mode)
selinux <- if (nzchar(Sys.getenv("WS_SELINUX"))) ",z" else ""

config <- list(
  proxy = list(
    title = def$title,
    port = 8080L,
    `landing-page` = "SingleApp",
    `hide-navbar` = TRUE,                     # participants get only the tutorial (it has its own Sign out)
    `template-path` = "/opt/shinyproxy/templates",   # our login and signed-out pages
    `heartbeat-rate` = 10000L,
    `heartbeat-timeout` = as.integer(Sys.getenv("WS_IDLE_MS", "1800000")),  # stop a session 30 min after its tab closed
    `default-stop-proxy-on-logout` = TRUE,     # signing out stops the session: signing in again gives a fresh one
    `container-wait-time` = 60000L,
    `container-backend` = "docker",
    docker = list(`internal-networking` = TRUE),
    authentication = "simple",
    users = unname(lapply(names(users), function(id) list(name = id, password = users[[id]]$password, groups = users[[id]]$group))),
    specs = list(
      list(
        id = "tutorial", `display-name` = def$title,
        `container-image` = IMAGE,
        `container-network` = "rworkshop",
        `container-env` = list(WS_API = "http://api:8000", WS_TOKEN_FILE = "/run/ws/token",
                               WS_DATA = "/data/synthea-covid19-10k.duckdb",
                               WS_TUTORIAL = sprintf("workshops/%s/tutorial.Rmd", WORKSHOP)),
        `container-volumes` = list(mount(host("tokens", "#{proxy.userId}"), "/run/ws", paste0("ro", selinux)),
                                   mount(host("data"), "/data", paste0("ro", selinux))),
        `container-memory-limit` = Sys.getenv("WS_MEMORY", "2g"),
        `container-cpu-limit` = as.numeric(Sys.getenv("WS_CPUS", "2")),
        `access-groups` = list("participants")
      ),
      list(
        id = "facilitator", `display-name` = paste(def$title, "- facilitator"),
        `container-image` = IMAGE,
        `container-cmd` = list("Rscript", "-e", "shiny::runApp(shiny::shinyAppFile('/srv/workshop/app/facilitator.R'), host = '0.0.0.0', port = 3838)"),
        `container-network` = "rworkshop",
        `container-env` = list(WS_API = "http://api:8000", WS_TOKEN_FILE = "/run/ws/token"),
        `container-volumes` = list(mount(host("tokens", "admin"), "/run/ws", paste0("ro", selinux))),
        `heartbeat-timeout` = -1L,              # the facilitator page is never stopped for being idle
        `access-groups` = list("admin")
      )
    )
  ),
  server = list(`forward-headers-strategy` = "native")
)
write_secret(p("shinyproxy", "application.yml"), yaml::as.yaml(config))

# The login and signed-out pages, with the logo embedded.
svg_uri <- function(name) {
  f <- file.path("/srv/workshop/branding", name)
  paste0("data:image/svg+xml;base64,", jsonlite::base64_enc(readBin(f, "raw", file.size(f))))
}
dir.create(p("shinyproxy", "templates"), recursive = TRUE, showWarnings = FALSE)
for (f in list.files("/srv/workshop/server/login-pages", full.names = TRUE)) {
  html <- readLines(f, warn = FALSE)
  html <- gsub("{{LOGO}}", svg_uri("hanze-logo.svg"), html, fixed = TRUE)
  html <- gsub("{{PAYOFF}}", svg_uri("hanze-payoff.svg"), html, fixed = TRUE)
  writeLines(html, p("shinyproxy", "templates", basename(f)))
}
message("Wrote run/shinyproxy/application.yml (contains passwords: keep it private).")
