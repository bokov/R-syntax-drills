source("R/question_manifest.R")
source("R/assignment_storage.R")
source("R/player_builder.R")

output_dir <- "student-assets"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

manifest <- build_player_assets(
  config = NULL,
  pool_output = file.path(output_dir, "runtime_question_pool.Rmd"),
  manifest_output = file.path(output_dir, "question_manifest.csv")
)

message(
  "Published student-safe runtime assets in ", output_dir,
  "; bank version ", unique(manifest$bank_version), "."
)
