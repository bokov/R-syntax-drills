test_that("scanner reads topic metadata", {
  manifest <- scan_question_bank(test_path("fixtures", "valid.Rmd"))

  expect_equal(nrow(manifest), 1)
  expect_equal(manifest$item_label, "vector_index")
  expect_equal(manifest$event, "exercise_result")
  expect_equal(manifest$topic, "vector_indexing")
  expect_equal(manifest$points, 1)
})

test_that("missing topic defaults to unassigned", {
  expect_warning(
    manifest <- scan_question_bank(test_path("fixtures", "missing_topic.Rmd")),
    "unassigned"
  )

  expect_equal(manifest$topic, "unassigned")
  expect_equal(manifest$points, 1)
})

test_that("explicit points metadata is preserved", {
  manifest <- scan_question_bank(test_path("fixtures", "explicit_points.Rmd"))

  expect_equal(manifest$points, 0)
})

test_that("duplicate question labels are rejected", {
  expect_error(
    scan_question_bank(test_path("fixtures", "duplicate_labels.Rmd")),
    "Duplicate question label"
  )
})
