source("R/question_manifest.R")
source("R/assignment_storage.R")
source("R/player_builder.R")

args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 1L) {
  stop("Usage: Rscript scripts/09_build_student_assets.R [release]")
}
release <- if (length(args)) args[[1]] else NULL

output_dir <- "student-assets"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

manifest <- build_player_assets(
  config = NULL,
  pool_output = file.path(output_dir, "runtime_question_pool.Rmd"),
  manifest_output = file.path(output_dir, "question_manifest.csv"),
  release = release
)

message(
  "Published student-safe runtime assets in ", output_dir,
  "; manifest release ", unique(manifest$release), "."
)

message(
  "Reminder: include changes to student-assets/runtime_question_pool.Rmd and ",
  "student-assets/question_manifest.csv in the same commit as the authoring ",
  "changes they publish."
)
