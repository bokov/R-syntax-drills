source("R/app_config.R")
source("R/question_manifest.R")

# Build and validate locally before deployment. The canonical question bank is
# deliberately NOT deployed because it contains solutions/checkers that should
# not be readable by student-submitted R code.
build_question_manifest()

if (grepl("PASTE_", APP_CONFIG$webhook_url, fixed = TRUE)) {
  stop("Set APP_CONFIG$webhook_url before deploying.")
}

runtime_r_files <- setdiff(
  list.files("R", recursive = TRUE, full.names = TRUE),
  c("R/gradebook.R","R/app_config_example.R")
) %>% grep("\\.bak$",.,inv=T,val=T)

app_files <- c(
  "index.Rmd",
  "question_manifest.csv",
  runtime_r_files,
  list.files("www", recursive = TRUE, full.names = TRUE)
)

rsconnect::deployApp(
  appDir = ".",
  appFiles = app_files,
  appPrimaryDoc = "index.Rmd",
  appName = APP_CONFIG$app_name,
  appMode = "rmd-shiny",
  launch.browser = TRUE
)
