source("R/app_config.R")

if (grepl("PASTE_", APP_CONFIG$webhook_url, fixed = TRUE)) {
  stop("Set APP_CONFIG$webhook_url before deploying.")
}

app_files <- c(
  "index.Rmd",
  list.files("R", recursive = TRUE, full.names = TRUE),
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
