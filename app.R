source("R/runtime_bank.R")

DRILLR_BOOT_BANK <- refresh_runtime_bank(
  bundled_manifest_path = "question_manifest.csv",
  bundled_pool_path = "runtime_question_pool.Rmd",
  cache_dir = "."
)

build_drillr_app <- function() {
  needs_render <- isTRUE(DRILLR_BOOT_BANK$updated) || !file.exists("index.html")
  if (needs_render) {
    rmarkdown::shiny_prerendered_clean("index.Rmd")
  }

  old_prerender <- Sys.getenv("RMARKDOWN_RUN_PRERENDER", unset = NA_character_)
  on.exit({
    if (is.na(old_prerender)) {
      Sys.unsetenv("RMARKDOWN_RUN_PRERENDER")
    } else {
      Sys.setenv(RMARKDOWN_RUN_PRERENDER = old_prerender)
    }
  }, add = TRUE)
  Sys.setenv(RMARKDOWN_RUN_PRERENDER = if (needs_render) "1" else "0")

  app_factory <- getFromNamespace("shiny_prerendered_app", "rmarkdown")
  app_factory(
    "index.Rmd",
    render_args = list(envir = globalenv())
  )
}

build_drillr_app()
