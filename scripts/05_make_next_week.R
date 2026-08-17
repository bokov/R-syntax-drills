args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2) {
  stop("Usage: Rscript scripts/05_make_next_week.R <new-week-id> <destination-directory>")
}

new_week <- args[[1]]
destination <- normalizePath(args[[2]], mustWork = FALSE)
source("R/app_config.R")

if (dir.exists(destination)) stop("Destination already exists: ", destination)
dir.create(destination, recursive = TRUE)

files <- list.files(
  ".",
  all.files = TRUE,
  no.. = TRUE,
  recursive = TRUE,
  full.names = TRUE
)
files <- files[!grepl("^(./)?(output|rsconnect|\\.Rproj\\.user)(/|$)", files)]

for (src in files) {
  target <- file.path(destination, src)
  dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
  file.copy(src, target, overwrite = TRUE)
}

config_path <- file.path(destination, "R", "app_config.R")
config_text <- readLines(config_path, warn = FALSE)
config_text <- sub(
  'week_id = "[^"]+"',
  paste0('week_id = "', new_week, '"'),
  config_text
)
config_text <- sub(
  'app_name = "[^"]+"',
  paste0('app_name = "r-syntax-', gsub("[^A-Za-z0-9-]", "-", new_week), '"'),
  config_text
)
writeLines(config_text, config_path)

rmd_path <- file.path(destination, "index.Rmd")
rmd <- readLines(rmd_path, warn = FALSE)
rmd <- sub('title: "R Syntax Drill — [^"]+"', paste0('title: "R Syntax Drill — ', new_week, '"'), rmd)
rmd <- sub('  id: "r-syntax-drills-[^"]+"', paste0('  id: "r-syntax-drills-', gsub("[^A-Za-z0-9-]", "-", new_week), '"'), rmd)
rmd <- sub('  version: [0-9.]+', paste0('  version: ', format(Sys.Date(), "%Y%m%d")), rmd)
writeLines(rmd, rmd_path)

message("Created: ", destination)
message("Now edit the drills and APP_CONFIG$scored_items in the new copy.")
