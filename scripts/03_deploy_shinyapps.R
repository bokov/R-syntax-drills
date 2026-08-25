source("R/app_config.R")
source("R/runtime_bank.R")

# The published student-safe pair is the hosted app's local copy too. Do not
# rebuild it implicitly here: rewording an existing question should reach
# clients only when the published manifest changes (for example by bumping its
# release before running scripts/09_build_student_assets.R).
published_manifest <- file.path("student-assets", "question_manifest.csv")
published_pool <- file.path("student-assets", "runtime_question_pool.Rmd")
if (!all(file.exists(c(published_manifest, published_pool)))) {
  stop(
    "Published student assets are missing. Run scripts/09_build_student_assets.R first."
  )
}

published_bank <- runtime_bank_from_pair(published_manifest, published_pool)
if (nzchar(published_bank$warning)) warning(published_bank$warning, call. = FALSE)

if (!file.copy(published_manifest, "question_manifest.csv", overwrite = TRUE)) {
  stop("Could not stage the published question manifest for deployment.")
}
if (!file.copy(published_pool, "runtime_question_pool.Rmd", overwrite = TRUE)) {
  stop("Could not stage the published runtime question pool for deployment.")
}

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
