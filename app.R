source("R/runtime_bank.R")

# Prepare the runtime bank before the Shiny app factory is built so both the
# app shell and the prerendered tutorial use the same reconciled manifest/pool.
DRILLR_BOOT_BANK <- refresh_runtime_bank(
  bundled_manifest_path = "question_manifest.csv",
  bundled_pool_path = "runtime_question_pool.Rmd",
  cache_dir = "."
)
options(drillr.runtime_bank = DRILLR_BOOT_BANK)

#' Build the hosted Drillr Shiny application
#'
#' Re-renders the shiny-prerendered tutorial only when the boot-time runtime bank
#' changed or no compiled HTML exists, temporarily sets rmarkdown's prerender
#' switch to match that decision, and returns the Shiny application generated
#' from `index.Rmd`.
#'
#' @return The Shiny application object returned by rmarkdown's internal
#'   `shiny_prerendered_app()` factory.
#' @details Called once at the bottom of `app.R`, which is the shinyapps.io app
#'   entry point. It depends on the boot-time `DRILLR_BOOT_BANK` produced by
#'   `refresh_runtime_bank()` and on `index.Rmd`; it has no other within-repo
#'   function dependencies.
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
