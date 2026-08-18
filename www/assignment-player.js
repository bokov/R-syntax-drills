(function() {
  var handlersRegistered = false;

  function waitingElement() {
    return document.getElementById('assignment-waiting');
  }

  function assignmentTopic() {
    var waiting = waitingElement();
    return waiting ? waiting.closest('.section.level2') : document;
  }

  function exerciseElements() {
    return Array.prototype.slice.call(
      assignmentTopic().querySelectorAll('.tutorial-exercise[data-label]')
    );
  }

  function questionSection(exercise) {
    if (!exercise) return null;

    // learnr's tutorial format uses Pandoc section divs and emits each exercise
    // as .tutorial-exercise[data-label=<chunk label>]. Each generated question
    // has a level-4 heading, so its nearest level-4 section is the native
    // container for the heading, prompt, and exercise.
    var section = exercise.closest('.section.level4');
    if (section) section.classList.add('assignment-question');
    return section;
  }

  function questionSectionForLabel(label) {
    var exercise = exerciseElements().find(function(element) {
      return element.getAttribute('data-label') === label;
    });
    return questionSection(exercise);
  }

  function allQuestionBlocks() {
    var seen = [];
    exerciseElements().forEach(function(exercise) {
      var section = questionSection(exercise);
      if (section && seen.indexOf(section) < 0) seen.push(section);
    });
    return seen;
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
    var shown = 0;
    var destination = null;

    labels.forEach(function(label, index) {
      var block = questionSectionForLabel(label);
      if (!block) {
        console.error('Assigned question is missing from the player:', label);
        return;
      }

      if (!destination) destination = block.parentNode;
      if (destination && block.parentNode === destination) {
        // Re-appending native section divs preserves persisted assignment order
        // while all non-assigned question sections remain hidden.
        destination.appendChild(block);
      }

      block.style.display = 'block';
      block.dataset.assignmentOrder = String(index);
      shown += 1;
    });

    var waiting = waitingElement();
    if (waiting) {
      if (shown === labels.length && shown > 0) {
        waiting.style.display = 'none';
      } else if (labels.length > 0) {
        waiting.style.display = 'block';
        waiting.className = 'alert alert-danger';
        waiting.textContent =
          'Your assignment was created, but one or more assigned questions ' +
          'could not be found in this player. Rebuild the local player and reload.';
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

  // This script is inlined after runtime_question_pool.Rmd, so the rendered
  // question DOM already exists even if Shiny's browser object is not ready yet.
  hideAll();
  registerWhenReady();
})();
