packages <- c(
  "learnr",
  "gradethis",
  "shiny",
  "rmarkdown",
  "httr2",
  "rsconnect",
  "googlesheets4",
  "dplyr",
  "tidyr",
  "readr",
  "testthat"
)

missing <- setdiff(packages, rownames(installed.packages()))
if (length(missing)) install.packages(missing)

message("All required packages are installed.")
