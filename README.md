# Weekly `learnr` syntax drills with automatic grading and Google Sheets logging

This project implements a browser-based weekly R syntax drill using:

- `learnr` for the interactive tutorial;
- `gradethis` for immediate automatic grading;
- a Google Apps Script web app for append-only event logging and persistent assignment storage;
- an instructor-side R script that converts the event and assignment records into a gradebook;
- `rsconnect` for deployment to shinyapps.io (or another Shiny host).

The Google Apps Script design deliberately avoids putting a Google service-account credential inside a `learnr` application that executes student-supplied R code.

## 1. Install the R packages

From the project directory:

```r
source("scripts/01_install_packages.R")
```

## 2. Create the Google grading spreadsheet and service

1. Create a new Google Sheet. It can be private to the instructor.
2. In that Sheet, open **Extensions > Apps Script**.
3. Replace the generated `Code.gs` with `google-apps-script/Code.gs` from this project.
4. If you can edit the Apps Script manifest, replace it with `google-apps-script/appsscript.json`. Otherwise the default manifest is sufficient; Apps Script will request the spreadsheet permission when needed.
5. In Apps Script, select and run `setupGradeSheet()` once. Approve the requested spreadsheet permission. This creates/verifies the `events`, `assignments`, and `question_bank` tabs, appends any new trailing schema columns, and freezes the header rows. It does **not** erase existing event or assignment rows.
6. Choose **Deploy > New deployment > Web app**.
7. Configure the web app to **execute as you** (the instructor/script owner). Grant access to **Anyone** if your Google Workspace policy permits it.
8. Deploy and copy the production URL ending in `/exec` (not the `/dev` test URL).
9. Copy the spreadsheet ID from the Google Sheet URL. It is the long string between `/d/` and `/edit`.

The event-logging operation is append-only. The same POST endpoint also has assignment-service operations that can read a student's assignment rows and create them once, idempotently. It does not provide an endpoint for reading, changing, or deleting grades or event history.

**Important:** The Apps Script web app is not student authentication. A determined student who discovers its URL can submit bogus event rows and, because student identity is self-asserted in this lightweight architecture, can query assignment rows using another student's ID. Assignment responses contain assignment metadata, not grades or performance history. For high-stakes assessment, use authenticated hosting/LMS identity.

## 3. Configure the week

Edit `R/app_config.R`:

```r
APP_CONFIG <- list(
  course_id = "R101",
  week_id = "week-01",
  app_name = "r-syntax-week-01",
  google_sheet_id = "YOUR_SHEET_ID",
  webhook_url = "YOUR_APPS_SCRIPT_EXEC_URL",
  deadline_utc = NA_character_
)
```

`deadline_utc` is optional. If set (for example, `"2026-09-04 23:59:59"`), the gradebook script ignores attempts recorded after that UTC deadline.

Scored items are derived from the generated question manifest. There is no separate item list in `APP_CONFIG`.

After changing the canonical question bank, synchronize its safe metadata to the private `question_bank` tab:

```r
source("scripts/06_sync_question_bank.R")
```

## 4. Test Google logging before giving the drill to students

Run:

```r
source("scripts/02_test_webhook.R")
```

Confirm that the `events` tab gets one row with student ID `INSTRUCTOR_TEST` and event `logging_test`.

You can test the assignment service separately with:

```r
source("scripts/07_test_assignment_service.R")
```

That smoke test deliberately leaves its `INSTRUCTOR_ASSIGNMENT_TEST_*` rows in the `assignments` tab as an audit trail. Those assignment-only test IDs are not treated as students by the gradebook unless they are placed in `roster.csv` or have logged student events.

## 5. Run the tutorial locally

In RStudio, open `index.Rmd` and click **Run Document**, or run:

```r
rmarkdown::run("index.Rmd")
```

The tutorial rebuilds `question_manifest.csv` when its server process starts, so local runs use the same question metadata as deployed runs.

When a valid student ID is saved, the app atomically gets or creates one persistent assignment row for each question in the current static assignment. Re-saving the same student/week identity returns those same rows rather than creating another exposure. The app caches the resulting label-to-`assignment_id` mapping for the session.

Each `exercise_result` or `question_submission` event is then logged with the corresponding `assignment_id`. Multiple submissions of the same question during that weekly assignment therefore remain multiple **attempts** against one **exposure**, rather than becoming multiple exposures.

The exercises are not yet hidden before identity is saved. If a student submits an attempt first and then saves identity in the same Shiny session, the existing identity-backfill behavior still recovers the attempt for grading; the historical event may simply lack an `assignment_id`.

## 6. Deploy to shinyapps.io

First configure `rsconnect` for your shinyapps.io account in the normal way. The deployment script builds and validates `question_manifest.csv` from the canonical question bank before deployment. Then run:

```r
source("scripts/03_deploy_shinyapps.R")
```

The deployment script sends only the runtime files (`index.Rmd`, `question_manifest.csv`, `R/`, and `www/`). The Apps Script source, roster, local grade output, instructor scripts, and canonical question bank are not deployed.

Distribute the resulting app URL to students. They need only a browser; they do not need R installed locally.

## 7. Automatic grading behavior

`gradethis` checks each submission immediately in the tutorial. The logging handler records the resulting `correct` flag from `learnr`'s `exercise_result` event.

The supplied grading rule is:

> A student earns the configured points for an assigned item if they produce at least one correct submission before the deadline. Unlimited incorrect attempts do not reduce the score.

Multiple attempts affect the attempt count in the detail output but do not create additional assignment exposures.

## 8. Build the weekly gradebook

For complete class rosters, copy `roster.csv.example` to `roster.csv` and replace the example rows. `roster.csv` is ignored by Git and not deployed.

Then run:

```r
source("scripts/04_build_gradebook.R")
```

On the first run, `googlesheets4` asks the instructor to authenticate interactively. The script:

1. reads the private `events` and `assignments` tabs;
2. filters both to `APP_CONFIG$course_id` / `APP_CONFIG$week_id` and applies the optional event deadline;
3. links attempts to the student's saved identity by Shiny session;
4. uses each student's persisted assignment rows as the denominator and verifies that the persisted static assignment still matches the current manifest;
5. determines whether each assigned item was ever answered correctly and counts all attempts separately;
6. writes `output/grades_<week>.csv` and `output/item_detail_<week>.csv`;
7. overwrites the corresponding `grades_<week>` and `detail_<week>` tabs in the Google spreadsheet.

`detail_<week>` includes `assignment_id`, `assignment_reason`, `assigned_at_utc`, and `question_hash`, so one question exposure can be distinguished from the number of attempts made against it.

As a migration safeguard, roster/event students who have no persisted assignment rows yet retain the old static-manifest denominator with `assignment_reason = "legacy_static_fallback"`. This prevents pre-migration students and roster no-shows from becoming 0/0 records. Once a student saves identity under the new app, the persisted assignment rows take over.

A partial or stale persisted static assignment is treated as an error rather than silently reducing the denominator. If canonical content or scoring changes after students have been assigned a week, use a new `week_id` rather than altering that week's meaning in place.

## 9. Make next week's copy

From the current week's directory:

```bash
Rscript scripts/05_make_next_week.R week-02 ../r-syntax-week-02
```

This creates a new project copy and updates the week ID, deployment name, tutorial ID, and tutorial version. Then select canonical question blocks from `question-bank/` and copy them into `index.Rmd`.

A unique tutorial ID/version each week prevents `learnr` from restoring a previous week's browser state into the new assignment.

## Editing or adding drills

A graded code exercise has three pieces:

```r
# exercise chunk
# solution chunk
# check chunk using gradethis::grade_this()
```

The helper functions in `R/syntax_checkers.R` inspect parsed R code and let you require syntax, not merely the final value. For example:

```r
uses_call(.user_code, "[[")
uses_token(.user_code, "|>")
call_has_named_arg(.user_code, "mean", "na.rm")
```

This makes it possible to distinguish “got the right answer” from “used the R syntax this drill is teaching.”

### Canonical question bank and assignment copies

Canonical questions live only under `question-bank/`. Question IDs (`item_label`s) are permanent and globally unique there; do not reuse an existing ID for a substantively different question.

The current authoring workflow remains manual: browse `question-bank/`, copy the complete question you want into `index.Rmd`, then run or deploy the tutorial. `index.Rmd` is a derived assignment, not another source of canonical questions.

New or modified canonical questions should have explicit boundaries:

```text
<!-- question: vector_c01 -->
## Vector Drill C01

[question prompt, setup, exercise, solution, and checker]

<!-- /question -->
```

The marker ID must equal the exercise/question chunk label. Existing pre-marker bank files remain supported by treating a level-2 section containing one question chunk as one question block.

Canonical metadata include `topic`, `points`, and `starter_question`. New or modified questions should specify `topic=` explicitly. Older bank files predate topic metadata, so `R/question_manifest.R` contains a compatibility registry based on their permanent ID families:

- `vector_c*` → `vector_creation`
- `vector_e*` → `vector_indexing`
- `df_r*`, `df_c*`, and `df_b*` → `dataframe_indexing`
- `df_s*` → `subset_function`
- `expr_d*` → `expression_decomposition`

Explicit `topic=` metadata always override the compatibility registry. The real canonical-bank test requires that the complete bank scan without any `unassigned` topic.

The expression-decomposition items are represented in the canonical manifest as zero-point `question_submission` items. They can therefore carry stable IDs/topics for future routing without changing the current eight scored exercises.

`R/question_manifest.R` produces two build artifacts:

- `question_bank_manifest.csv` describes every canonical bank question, including `item_label`, `topic`, `points`, `starter_question`, source location, and a normalized `question_hash`.
- `question_manifest.csv` describes only the questions copied into the current `index.Rmd`, after verifying that every ID exists in the canonical bank and that the full question content matches its canonical copy.

Both CSVs are generated output and should not be edited by hand. The canonical bank itself is intentionally not deployed to shinyapps.io because it contains solutions and check code. Deployment validates locally and sends only the derived `question_manifest.csv` plus the tutorial runtime files.

`starter_question=TRUE` remains reserved for future first-time-student routing; the current assignment selection is still static and identical for every student.

### Persistent assignments and exposures

The Google workbook separates three concepts:

- `question_bank`: private canonical metadata inventory;
- `assignments`: which literal questions were assigned to which student/week;
- `events`: each submission/attempt the student made.

One `assignments` row is one question **exposure**. Several event rows may point to that same `assignment_id`, so repeated attempts within a week do not inflate the future exposure count.

For the current static phase, saving identity calls `get_or_create_assignments` with every item in the validated `question_manifest.csv` and `assignment_reason = "static"`. The backend is all-or-existing and idempotent: if any assignment rows already exist for that student/course/week, it returns them rather than replacing or topping them up. The runtime then verifies that the returned item set and topic/points/hash snapshots exactly match the current static manifest.

This establishes reliable exposure history now while every student still receives the same questions. Later routing PRs can change **which item IDs are selected** without replacing the assignment, logging, or grading data model.

Run the automated R tests with:

```r
source("tests/testthat.R")
```

## Security / reliability notes

- `learnr` executes student-submitted R. Treat students as untrusted code authors and use hosting isolation appropriate to the stakes of the course.
- The Google Sheet remains private. The deployed tutorial has no Google account credential and cannot access the spreadsheet directly; it communicates only through the Apps Script operations exposed by the configured web-app URL.
- Event logging is append-only. Assignment-service operations can read/create assignment metadata, but there is no web-app operation for reading grades/performance history or changing/deleting event rows.
- Assignment identity has the same limitation as the rest of this lightweight setup: `student_id` is self-asserted. Do not treat the assignment lookup operation as authentication.
- The Apps Script validates schemas and field sizes, serializes event writes and assignment creation with `LockService`, and prefixes formula-like text before writing student-controlled values to the Sheet.
- shinyapps.io local filesystem storage is ephemeral; the authoritative event and assignment records are in the Google Sheet.
- For high-stakes grading, use an authenticated host or LMS integration.
