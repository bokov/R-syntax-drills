# One-command instructor workflow after editing R/app_config.R and/or the
# canonical question bank: validate + sync metadata + rebuild + deploy.
source("scripts/06_sync_question_bank.R")
source("scripts/03_deploy_shinyapps.R")
