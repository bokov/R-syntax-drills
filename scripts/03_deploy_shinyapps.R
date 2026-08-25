source("R/app_config.R")
source("R/question_manifest.R")
source("R/assignment_storage.R")
source("R/player_builder.R")
source("R/runtime_bank.R")

# Build and validate locally before deployment. The canonical question bank is
# deliberately NOT deployed; the runtime player contains only scored exercise
# blocks and omits their *-solution chunks. Keep the same explicit release as
# the published student manifest unless it is intentionally bumped first.
published_manifest <- file.path("student-assets", "question_manifest.csv")
release <- current_manifest_release(published_manifest)
build_player_assets(config = APP_CONFIG, release = release)

# Ship a compiled copy with the deployment. app.R checks the main-branch
# manifest before starting each hosted Shiny worker and re-renders only when it
# actually downloads a changed runtime pool (or when the compiled copy is
# missing).
rmarkdown::shiny_prerendered_clean("index.Rmd")
local({
  old_bank <- getOption("drillr.runtime_bank")
  on.exit(options(drillr.runtime_bank = old_bank), add = TRUE)
  options(drillr.runtime_bank = NULL)
  rmarkdown::render(
    "index.Rmd",
    output_file = "index.html",
    envir = new.env(parent = globalenv()),
    quiet = TRUE
  )
})

if (grepl("PASTE_", APP_CONFIG$webhook_url, fixed = TRUE)) {
  stop("Set APP_CONFIG$webhook_url before deploying.")
}

runtime_r_files <- setdiff(
  list.files("R", recursive = TRUE, full.names = TRUE),
  c(
    "R/gradebook.R",
    "R/app_config_example.R",
    "R/review_question_bank.R",
    "R/player_builder.R"
  )
) |>
  grep("\\.bak$", x = _, invert = TRUE, value = TRUE)

app_files <- c(
  "app.R",
  "index.Rmd",
  "index.html",
  "runtime_question_pool.Rmd",
  "question_manifest.csv",
  runtime_r_files,
  list.files("index_files", recursive = TRUE, full.names = TRUE),
  list.files("www", recursive = TRUE, full.names = TRUE)
)

rsconnect::deployApp(
  appDir = ".",
  appFiles = app_files,
  appName = APP_CONFIG$app_name,
  appMode = "shiny",
  launch.browser = TRUE
)
