function migrateLegacyPlaceholderHeaders(ss) {
  const specs = [
    { sheetName: ASSIGNMENT_SHEET, headers: ASSIGNMENT_HEADERS, ignored: [7] },
    { sheetName: QUESTION_BANK_SHEET, headers: QUESTION_BANK_HEADERS, ignored: [5, 6] }
  ];

  specs.forEach(function(spec) {
    const sheet = ss.getSheetByName(spec.sheetName);
    if (!sheet || sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) return;

    const current = sheet
      .getRange(1, 1, 1, sheet.getLastColumn())
      .getValues()[0];
    if (current.length !== spec.headers.length) return;

    for (let ii = 0; ii < current.length; ii++) {
      if (spec.ignored.includes(ii)) continue;
      if (current[ii] !== spec.headers[ii]) return;
    }

    spec.ignored.forEach(function(ii) {
      sheet.getRange(1, ii + 1).setValue(spec.headers[ii]);
    });
  });
}
