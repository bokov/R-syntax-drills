# Weekly `learnr` syntax drills with automatic grading and Google Sheets logging

This project provides browser-based weekly R syntax drills using:

- `learnr` for interactive exercises;
- `gradethis` for immediate automatic grading;
- a Google Apps Script web app for append-only event logging and persistent weekly assignments;
- Google Sheets as the authoritative assignment/event store;
- an instructor-side gradebook builder;
- `rsconnect` for deployment to shinyapps.io.

The canonical question bank lives under `question-bank/`. `index.Rmd` is now a stable **player template**, not a weekly hand-edited assignment. Which questions a student sees is determined by persistent assignment rows created from question-bank metadata and `APP_CONFIG`.

## 1. Install packages

From the project directory:

```r
source("scripts/01_install_packages.R")
```

## 2. Create or update the Google grading service

For a new spreadsheet:

1. Create a private Google Sheet.
2. Open **Extensions > Apps Script**.
3. Replace the generated `Code.gs` with `google-apps-script/Code.gs` from this repository.
4. If you can edit the Apps Script manifest, replace it with `google-apps-script/appsscript.json`; otherwise the default manifest is sufficient.
5. Run `setupGradeSheet()` once and approve the requested permission. It creates/verifies `events`, `assignments`, and `question_bank` and does not erase existing assignment/event rows.
6. Choose **Deploy > New deployment > Web app**.
7. Set **Execute as** to yourself (the instructor/script owner) and permit **Anyone** if your Workspace policy allows it.
8. Deploy and copy the production URL ending in `/exec`.
9. Copy the Google Sheet ID from the Sheet URL.

### Updating an existing installation after assignment-service code changes

When `google-apps-script/Code.gs` changes in this repository, editing the Apps Script source is not by itself enough for an existing versioned web-app deployment. In Apps Script:

1. Replace `Code.gs` with the new repository version.
2. Run `setupGradeSheet()` once to verify the existing sheet schemas.
3. Open **Deploy > Manage deployments**.
4. Edit the existing web-app deployment.
5. Select **New version** and deploy it.
6. Keep the same `/exec` URL in `R/app_config.R` unless Google gives you a different one.

The event endpoint is append-only. The assignment endpoint can read a student's own requested assignment metadata and idempotently create a weekly assignment. It does not expose grades or event history.

## 3. Configure the course and unlocked topics

The real configuration is `R/app_config.R`, which is ignored by Git. Start from `R/app_config_example.R` if needed.

```r
APP_CONFIG <- list(
  course_id = "R101",
  week_id = "week-01",
  app_name = "r-syntax-drills",
  questions_per_week = 10L,
  unlocked_topics = c(
    "vector_creation",
    "vector_indexing"
  ),
  google_sheet_id = "YOUR_SHEET_ID",
  webhook_url = "YOUR_APPS_SCRIPT_EXEC_URL",
  deadline_utc = NA_character_
)
```

### `app_name`

Keep `app_name` stable from week to week so `rsconnect` updates the same deployed app and student URL. If you already have a deployed app name you want to preserve, keep that existing value rather than renaming it just to match the example.

### `week_id`

`week_id` is the explicit weekly boundary. The system does **not** advance itself based on the calendar. A student's persisted assignment is keyed by `(course_id, week_id, student_id)`.

To start a new week, change only this value if the curriculum settings are otherwise unchanged:

```r
week_id = "week-02"
```

Then publish the week as described below.

### `questions_per_week`

This is the number of questions assigned to a **returning** student in a newly created week. It must be a positive integer. New students instead receive every currently eligible question marked `starter_question=TRUE`.

### `unlocked_topics`

This is a hard eligibility filter for automatic assignment. Only scored exercises whose canonical `topic` is listed here can be selected.

For example, early in the course:

```r
unlocked_topics = c(
  "vector_creation",
  "vector_indexing"
)
```

Later you might use:

```r
unlocked_topics = c(
  "vector_creation",
  "vector_indexing",
  "dataframe_indexing",
  "subset_function"
)
```

A topic name must exactly match canonical question metadata. Publishing/sync validation fails on unknown topic names. If a starter question belongs to a locked topic, validation warns that it is not currently starter-eligible.

Changing `unlocked_topics` does not alter an assignment that has already been persisted for the current student/week. It changes only future assignment creation.

### Starter questions

Mark a canonical exercise as a starter directly in its exercise chunk metadata:

````text
```{r vector_c01c, exercise=TRUE, topic="vector_creation", starter_question=TRUE}
```
````

A brand-new student receives **all** scored starter questions whose topics are unlocked. There is no second hard-coded starter list. Publishing fails if no starter question is eligible.

The current vector bank defines these ten starters:

- `vector_c01c`
- `vector_c03b`
- `vector_c04d`
- `vector_c09a`
- `vector_e01b`
- `vector_e02c`
- `vector_e06a`
- `vector_e09d`
- `vector_e10b`
- `vector_e25a`

## 4. Sync and publish everything

The normal instructor workflow is deliberately one command after editing `R/app_config.R` and/or canonical question-bank files:

```r
source("scripts/08_publish_week.R")
```

That command does, in order:

1. rebuild and validate the complete canonical question-bank manifest;
2. validate `questions_per_week`, `unlocked_topics`, and starter availability;
3. overwrite the private Google Sheet `question_bank` tab with current safe metadata, including `topic`, `points`, `starter_question`, and `question_hash`;
4. build the deployable scored-question pool and `question_manifest.csv`;
5. build a runtime copy of the player whose `learnr` tutorial version equals the current `week_id`, preventing browser state from one week from being reused as the next week's tutorial state;
6. deploy/update the configured shinyapps.io app.

You therefore do **not** manually edit `index.Rmd` when choosing questions or advancing the course.

If you only want to synchronize Google question-bank metadata without deploying:

```r
source("scripts/06_sync_question_bank.R")
```

If you only want to deploy after everything is already synchronized:

```r
source("scripts/03_deploy_shinyapps.R")
```

## 5. How assignment selection works

When a valid student ID is saved:

1. If assignment rows already exist for that `(course_id, week_id, student_id)`, those exact rows are returned. Refresh/re-entry never resamples the week.
2. If this is the student's first assignment in the course, every eligible `starter_question=TRUE` exercise is assigned with `assignment_reason = "starter"`.
3. Otherwise, only questions in `unlocked_topics` are considered. Prior exposure count is computed from historical `assignments` rows for that student/course.
4. Questions with the lowest exposure count are preferred. Ties are randomized immediately.
5. The first `questions_per_week` candidates are persisted with `assignment_reason = "least_exposed"`.
6. A literal question can appear at most once in one weekly assignment. Multiple submissions during that week remain multiple attempts against the same `assignment_id`, so they count as one exposure.

This is the pre-adaptive selector. A later adaptive-routing change can first choose weak unlocked topics and then apply the same least-exposed/random-tie rule within those topics without changing the persistence/player model.

## 6. Run locally

Use the local player helper rather than running the template directly:

```r
source("scripts/00_run_local.R")
```

It validates the bank/config, creates the generated runtime question pool and week-specific runtime Rmd, and launches the tutorial.

Questions remain hidden until a valid student ID has successfully loaded/created its weekly assignment.

## 7. Testing before students use the app

### Automated tests

Run:

```r
source("tests/testthat.R")
```

The tests cover canonical metadata, dynamic-assignment payload/config validation, persisted-subset grading behavior, player generation, solution stripping from the runtime pool, week-specific tutorial versioning, and the agreed ten starter IDs.

### Webhook logging smoke test

Run:

```r
source("scripts/02_test_webhook.R")
```

Confirm one `logging_test` row appears in `events` for `INSTRUCTOR_TEST`.

### Dynamic assignment-service smoke test

After updating/redeploying the Apps Script code and synchronizing `question_bank`, run:

```r
source("scripts/07_test_assignment_service.R")
```

The script uses a fresh `INSTRUCTOR_ASSIGNMENT_TEST_*` ID and verifies all of the following against the live Apps Script service:

- the fresh current-week lookup is empty;
- the first assignment equals the currently eligible starter set;
- a repeated current-week request returns the same assignment IDs and creates no duplicate exposures;
- a synthetic next week recognizes the same ID as a returning student;
- the returning assignment contains exactly `questions_per_week` rows;
- every selected topic is unlocked;
- `assignment_reason` changes from `starter` to `least_exposed`;
- starter questions are not repeated when enough never-exposed eligible questions exist;
- repeating that synthetic week returns the same IDs.

The smoke-test assignment rows are deliberately retained as an audit trail. Assignment-only `INSTRUCTOR_ASSIGNMENT_TEST_*` IDs do not become gradebook students unless they also have student events or are placed in the roster.

### Manual end-to-end player test

Use a never-before-used student ID in an incognito/private browser window and check:

1. No exercise is visible before saving identity.
2. Saving identity reveals exactly the eligible starter questions; with the default vector configuration this should be 10.
3. The Google `assignments` tab receives one row per visible question, all with `assignment_reason = starter` and distinct `assignment_id`s.
4. Submit one wrong and then one correct attempt to the same question. Both event rows should reference the same nonblank `assignment_id`.
5. Close the browser, reopen the app, enter the same student ID, and verify no new assignment rows are created and the same questions return.
6. Run `source("scripts/04_build_gradebook.R")` and confirm the denominator equals that student's persisted assignment, not the full deployed question pool.

For an additional locked-topic check, temporarily configure a narrower `unlocked_topics`, publish to a test app/config, and verify the live assignment service never returns a question outside that set.

## 8. Build the weekly gradebook

Optionally copy `roster.csv.example` to ignored `roster.csv` and populate it. Then run:

```r
source("scripts/04_build_gradebook.R")
```

The gradebook reads `events` and `assignments`, filters to `APP_CONFIG$course_id` and `APP_CONFIG$week_id`, uses each student's persisted weekly assignment as the denominator, counts attempts separately from exposures, and writes both local CSVs and `grades_<week>` / `detail_<week>` tabs.

A student earns the assigned points for an item after at least one correct submission before the optional UTC deadline. Incorrect attempts do not reduce the score.

## 9. Canonical question authoring

Canonical questions live only under `question-bank/`. Question IDs (`item_label`) are permanent and globally unique. Do not reuse an existing ID for a substantially different literal question.

New/modified canonical questions should use explicit boundaries:

```text
<!-- question: vector_c01c -->
## Question title

[prompt/setup/exercise/solution/checker]

<!-- /question -->
```

The marker ID must match the exercise/question chunk label. Canonical metadata include `topic`, `points`, and `starter_question`.

The generated runtime player includes scored `exercise_result` questions from the canonical bank, but omits their `*-solution` chunks. The canonical bank itself is not deployed. Check chunks remain necessary for server-side grading.

`question_bank_manifest.csv`, `question_manifest.csv`, `runtime_question_pool.Rmd`, and `runtime_index.Rmd` are generated files and should not be edited or committed.

The former hand-curated Week 01 source is retained under `examples/legacy_static_week01.Rmd` for reference but is no longer part of the canonical bank or automatic selection pool.

## Security / reliability notes

- `learnr` executes student-supplied R. Use hosting isolation appropriate to the stakes of the course.
- The Google Sheet remains private; the deployed app has no Google account credential and communicates only through the Apps Script web endpoint.
- Student IDs are self-asserted in this lightweight architecture. Assignment lookup is not authentication.
- A student who deliberately unhides an unassigned exercise in browser developer tools may see/run it, but it has no matching weekly `assignment_id` and is not part of that student's persisted grading denominator.
- Assignment/event history in Google Sheets is authoritative; shinyapps.io local storage is not.
