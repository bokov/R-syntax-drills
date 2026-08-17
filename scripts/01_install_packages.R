packages <- c(
  "learnr",
  #"gradethis", # install manually from github 
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
