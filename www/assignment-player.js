(function() {
  var handlersRegistered = false;

  function exerciseForLabel(label) {
    var exercises = document.querySelectorAll('.tutorial-exercise[data-label]');
    var target = String(label);

    for (var ii = 0; ii < exercises.length; ii += 1) {
      if (exercises[ii].getAttribute('data-label') === target) {
        return exercises[ii];
      }
    }

    return null;
  }

  function questionBlockForExercise(exercise) {
    if (!exercise) return null;

    if (exercise.closest) {
      // Each generated question begins with a level-4 heading, so under the
      // standard rmarkdown/learnr HTML structure this is the whole prompt +
      // exercise + checker/support region for one canonical question.
      var block = exercise.closest('.section.level4');
      if (block) return block;

      block = exercise.closest('.section');
      if (block) return block;
    }

    // Last-resort fallback: at least reveal the learnr exercise itself.
    return exercise;
  }

  function allQuestionBlocks() {
    var exercises = document.querySelectorAll('.tutorial-exercise[data-label]');
    var blocks = [];

    for (var ii = 0; ii < exercises.length; ii += 1) {
      var block = questionBlockForExercise(exercises[ii]);
      if (block && blocks.indexOf(block) < 0) blocks.push(block);
    }

    return blocks;
  }

  function waitingElement() {
    return document.getElementById('assignment-waiting');
  }

  function hideAll() {
    allQuestionBlocks().forEach(function(block) {
      block.style.display = 'none';
    });

    var waiting = waitingElement();
    if (waiting) {
      waiting.style.display = 'block';
      waiting.className = 'alert alert-info';
      waiting.textContent =
        'Your questions will appear here after you save a valid student ID.';
    }
  }

  function showAssignments(message) {
    hideAll();

    var labels = (message && message.item_labels) || [];
    var blocks = [];
    var missing = [];

    labels.forEach(function(label, index) {
      var exercise = exerciseForLabel(label);
      var block = questionBlockForExercise(exercise);

      if (!block) {
        console.error('Assigned question is missing from the player:', label);
        missing.push(label);
        return;
      }

      block.dataset.assignmentOrder = String(index);
      blocks.push(block);
    });

    // Preserve persisted assignment order when the question sections share a
    // common parent (the normal learnr/rmarkdown structure). If they do not,
    // reveal them in place rather than failing.
    if (blocks.length) {
      var parent = blocks[0].parentNode;
      var sameParent = blocks.every(function(block) {
        return block.parentNode === parent;
      });

      if (sameParent && parent) {
        blocks.forEach(function(block) {
          parent.appendChild(block);
        });
      }

      blocks.forEach(function(block) {
        block.style.display = 'block';
      });
    }

    var waiting = waitingElement();
    if (waiting) {
      if (labels.length > 0 && missing.length === 0) {
        waiting.style.display = 'none';
      } else if (labels.length > 0) {
        waiting.style.display = 'block';
        waiting.className = 'alert alert-danger';
        waiting.textContent =
          'Your assignment was created, but these assigned questions could not ' +
          'be found in the rendered Learnr player: ' + missing.join(', ') + '.';
      } else {
        waiting.style.display = 'block';
      }
    }
  }

  function registerShinyHandlers() {
    if (handlersRegistered) return true;
    if (!window.Shiny || !window.Shiny.addCustomMessageHandler) return false;

    window.Shiny.addCustomMessageHandler('assignment:set', showAssignments);
    window.Shiny.addCustomMessageHandler('assignment:clear', function(message) {
      hideAll();
    });
    handlersRegistered = true;
    return true;
  }

  function registerWhenReady() {
    if (registerShinyHandlers()) return;

    var attempts = 0;
    var timer = window.setInterval(function() {
      attempts += 1;
      if (registerShinyHandlers() || attempts >= 200) {
        window.clearInterval(timer);
      }
    }, 50);
  }

  // The script is inlined after the generated question pool, so try immediately
  // and repeat once DOMContentLoaded fires in case learnr finishes DOM setup later.
  hideAll();
  registerWhenReady();

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      hideAll();
      registerWhenReady();
    });
  }
})();
