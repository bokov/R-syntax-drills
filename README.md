# Weekly `learnr` syntax drills with automatic grading and Google Sheets logging

This project implements a browser-based weekly R syntax drill using:

- `learnr` for the interactive tutorial;
- `gradethis` for immediate automatic grading;
- a Google Apps Script web app for append-only event logging and persistent assignment storage;
- an instructor-side R script that converts the event log into a gradebook;
- `rsconnect` for deployment to shinyapps.io (or another Shiny host).

The Google Apps Script design deliberately avoids putting a Google service-account credential inside a `learnr` application that executes student-supplied R code.

## 1. Install the R packages

From the project directory:

```r
source("scripts/01_install_packages.R")
```

## 2. Create the Google grading spreadsheet and logger

1. Create a new Google Sheet. It can be private to the instructor.
2. In that Sheet, open **Extensions > Apps Script**.
3. Replace the generated `Code.gs` with `google-apps-script/Code.gs` from this project.
4. If you can edit the Apps Script manifest, replace it with `google-apps-script/appsscript.json`. Otherwise the default manifest is sufficient; Apps Script will request the spreadsheet permission when needed.
5. In Apps Script, select and run `setupGradeSheet()` once. Approve the requested spreadsheet permission. This creates/verifies the `events`, `assignments`, and `question_bank` tabs, appends any new trailing schema columns, and freezes the header rows. It does **not** erase existing event or assignment rows.
6. Choose **Deploy > New deployment > Web app**.
7. Configure the web app to **execute as you** (the instructor/script owner). Grant access to **Anyone** if your Google Workspace policy permits it.
8. Deploy and copy the production URL ending in `/exec` (not the `/dev` test URL).
9. Copy the spreadsheet ID from the Google Sheet URL. It is the long string between `/d/` and `/edit`.

The event-logging operation remains append-only. The same POST endpoint also has assignment-service operations that can read a student's assignment rows and create them once, idempotently. It does not provide an endpoint for reading, changing, or deleting grades or event history.

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

## 4. Test Google logging before giving the drill to students

Run:

```r
source("scripts/02_test_webhook.R")
```

Confirm that the `events` tab gets one row with student ID `INSTRUCTOR_TEST` and event `logging_test`.

## 5. Run the tutorial locally

In RStudio, open `index.Rmd` and click **Run Document**, or run:

```r
rmarkdown::run("index.Rmd")
```

The tutorial rebuilds `question_manifest.csv` when its server process starts, so local runs use the same question metadata as deployed runs.

Enter a test student ID, solve an exercise, and verify that an `exercise_result` row appears in the Sheet.

Each `exercise_result` log contains the exercise label, submitted code, automatic correctness result, elapsed evaluation time, timeout indicator, and error message (if any). Question submissions are logged similarly. The `assignment_id` event column is currently nullable; a later runtime change will populate it when the tutorial begins loading persistent assignments.

## 6. Deploy to shinyapps.io

First configure `rsconnect` for your shinyapps.io account in the normal way. The deployment script builds `question_manifest.csv` from the R Markdown question chunks before deployment. Then run:

```r
source("scripts/03_deploy_shinyapps.R")
```

The deployment script sends only the runtime files (`index.Rmd`, `question_manifest.csv`, `R/`, and `www/`). The Apps Script source, roster, local grade output, instructor scripts, and canonical question bank are not deployed.

Distribute the resulting app URL to students. They need only a browser; they do not need R installed locally.

## 7. Automatic grading behavior

`gradethis` checks each submission immediately in the tutorial. The logging handler records the resulting `correct` flag from `learnr`'s `exercise_result` event.

The supplied grading rule is:

> A student earns the configured points for an item if they produce at least one correct submission before the deadline. Unlimited incorrect attempts do not reduce the score.

Change `scripts/04_build_gradebook.R` if you want attempt penalties, first-attempt grading, partial credit, or another policy.

## 8. Build the weekly gradebook

For complete class rosters, copy `roster.csv.example` to `roster.csv` and replace the example rows. `roster.csv` is ignored by Git and not deployed.

Then run:

```r
source("scripts/04_build_gradebook.R")
```

On the first run, `googlesheets4` asks the instructor to authenticate interactively. The script:

1. reads the private `events` tab;
2. filters to `APP_CONFIG$week_id` and the optional deadline;
3. links attempts to the student's saved identity by Shiny session;
4. determines whether each scored item was ever answered correctly;
5. writes `output/grades_<week>.csv` and `output/item_detail_<week>.csv`;
6. overwrites the corresponding `grades_<week>` and `detail_<week>` tabs in the Google spreadsheet.

Attempts made before a student clicks **Save identity** can still be recovered if the student saves their identity later in the same Shiny session, because the gradebook backfills identity by session token.

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

Canonical metadata live on the question chunk. `topic` and `points` retain their existing meanings, and `starter_question=TRUE` is available for future first-time-student routing. It does not change current assignment behavior.

`R/question_manifest.R` produces two build artifacts:

- `question_bank_manifest.csv` describes every canonical bank question, including `item_label`, `topic`, `points`, `starter_question`, source location, and a normalized `question_hash`.
- `question_manifest.csv` describes only the questions copied into the current `index.Rmd`, after verifying that every ID exists in the canonical bank and that the full question content matches its canonical copy.

Both CSVs are generated output and should not be edited by hand. The canonical bank itself is intentionally not deployed to shinyapps.io because it contains solutions and check code. Deployment validates locally and sends only the derived `question_manifest.csv` plus the tutorial runtime files.

### Persistent assignment infrastructure

The Google workbook now reserves two private metadata tabs for future individualized assignments:

- `question_bank` is an instructor-synchronized copy of canonical question metadata only. It does **not** contain prompt, solution, or checker code.
- `assignments` stores one row per assigned question exposure with `assignment_id`, course/week/student keys, canonical item metadata, assignment timestamp, and assignment reason.

After changing the canonical question bank, synchronize its metadata with:

```r
source("scripts/06_sync_question_bank.R")
```

The Apps Script supports two assignment operations over POST:

- `get_assignments` returns already-persisted rows for one `(course_id, week_id, student_id)`.
- `get_or_create_assignments` atomically returns existing rows or, if none exist, validates supplied item IDs against the private `question_bank` tab and creates the requested rows under a script lock.

Creation is intentionally all-or-existing: once any assignment rows exist for that student/week, a repeated create request returns those original rows rather than changing or topping up the assignment. This makes retries idempotent.

This infrastructure is **not yet used by `index.Rmd`**. Current students still receive the same manually copied static questions. After updating/redeploying the Apps Script and synchronizing `question_bank`, you can exercise the new API manually with:

```r
source("scripts/07_test_assignment_service.R")
```

That test deliberately leaves its `INSTRUCTOR_ASSIGNMENT_TEST_*` rows in the `assignments` tab as an audit trail.

Run the automated R tests with:

```r
source("tests/testthat.R")
```

V1.2 assumes the V1.1 event-log schema already includes the `topic` column. `setupGradeSheet()` now appends the nullable `assignment_id` event column and initializes the two assignment-storage tabs without deleting existing data.

## Security / reliability notes

- `learnr` executes student-submitted R. Treat students as untrusted code authors and use hosting isolation appropriate to the stakes of the course.
- The Google Sheet remains private. The deployed tutorial has no Google account credential and cannot access the spreadsheet directly; it communicates only through the Apps Script operations exposed by the configured web-app URL.
- Event logging is append-only. Assignment-service operations can read/create assignment metadata, but there is no web-app operation for reading grades/performance history or changing/deleting event rows.
- Assignment identity has the same limitation as the rest of this lightweight setup: `student_id` is self-asserted. Do not treat the assignment lookup operation as authentication.
- The Apps Script validates schemas and field sizes, serializes event writes and assignment creation with `LockService`, and prefixes formula-like text before writing student-controlled values to the Sheet.
- shinyapps.io local filesystem storage is ephemeral; the authoritative event and assignment records are in the Google Sheet.
- For high-stakes grading, use an authenticated host or LMS integration.
