test_that("revised vector bank has four variants of every logic family", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  vector_dir <- file.path(root, "question-bank", "vector_drills")
  vector_files <- sort(list.files(
    vector_dir,
    pattern = "\\.[Rr]md$",
    full.names = TRUE
  ))

  bank <- scan_question_bank(vector_files)

  expect_equal(nrow(bank), 148)
  expect_true(all(bank$topic %in% c("vector_creation", "vector_indexing")))
  expect_true(all(grepl("^vector_[ce][0-9]{2}[a-d]$", bank$item_label)))

  families <- sub("[a-d]$", "", bank$item_label)
  expect_true(all(table(families) == 4))
  expect_setequal(
    unique(families[grepl("^vector_c", families)]),
    sprintf("vector_c%02d", 1:17)
  )
  expect_setequal(
    unique(families[grepl("^vector_e", families)]),
    sprintf("vector_e%02d", 1:20)
  )
})

test_that("revised vector bank excludes retired drill mechanics", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  vector_dir <- file.path(root, "question-bank", "vector_drills")
  vector_files <- sort(list.files(
    vector_dir,
    pattern = "\\.[Rr]md$",
    full.names = TRUE
  ))
  text <- paste(
    unlist(lapply(vector_files, readLines, warn = FALSE), use.names = FALSE),
    collapse = "\n"
  )

  expect_false(grepl("NA_(real|integer|character|complex)_", text, perl = TRUE))
  expect_false(grepl("\\b[0-9]+L\\b", text, perl = TRUE))
  expect_false(grepl("\\b[0-9]+(?:\\.[0-9]+)?[eE][+-]?[0-9]+\\b", text, perl = TRUE))
  expect_false(grepl("\\b[0-9]+(?:\\.[0-9]+)?[+-][0-9]+i\\b", text, perl = TRUE))
  expect_false(grepl("(?m)^\\s*[A-Za-z]\\s*<-", text, perl = TRUE))
})

test_that("creation and indexing variants use the intended checker policies", {
  root <- normalizePath(file.path(test_path(), "..", ".."))
  vector_dir <- file.path(root, "question-bank", "vector_drills")

  creation_files <- list.files(
    vector_dir,
    pattern = "^creation_.*\\.[Rr]md$",
    full.names = TRUE
  )
  indexing_files <- list.files(
    vector_dir,
    pattern = "^indexing_.*\\.[Rr]md$",
    full.names = TRUE
  )

  creation_text <- paste(
    unlist(lapply(creation_files, readLines, warn = FALSE), use.names = FALSE),
    collapse = "\n"
  )
  indexing_text <- paste(
    unlist(lapply(indexing_files, readLines, warn = FALSE), use.names = FALSE),
    collapse = "\n"
  )

  expect_equal(length(gregexpr("<!-- question: vector_c", creation_text, fixed = TRUE)[[1]]), 68)
  expect_equal(length(gregexpr("check_vector_assignment(", creation_text, fixed = TRUE)[[1]]), 68)
  expect_equal(length(gregexpr("<!-- question: vector_e", indexing_text, fixed = TRUE)[[1]]), 80)
  expect_equal(length(gregexpr("check_vector_subscript(", indexing_text, fixed = TRUE)[[1]]), 80)

  expect_true(grepl("min_brackets = 2", indexing_text, fixed = TRUE))
  for (required in c("which", "grep", "match", "order", "startsWith", "is.na", "%in%", "seq")) {
    expect_true(
      grepl(paste0('required_calls = c("', required, '")'), indexing_text, fixed = TRUE),
      info = paste("missing required subscript-function family:", required)
    )
  }
})
