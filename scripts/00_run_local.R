source("R/app_config.R")
source("R/question_manifest.R")
source("R/assignment_storage.R")
source("R/player_builder.R")

build_player_assets(config = APP_CONFIG)
build_runtime_index(config = APP_CONFIG)

rmarkdown::run("runtime_index.Rmd")
