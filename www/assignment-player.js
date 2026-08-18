(function() {
  var handlersRegistered = false;

  function allQuestionBlocks() {
    return Array.prototype.slice.call(
      document.querySelectorAll('.assignment-question')
    );
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

    var pool = document.getElementById('assignment-question-pool');
    var labels = (message && message.item_labels) || [];
    var shown = 0;

    labels.forEach(function(label, index) {
      var block = document.getElementById('assignment-question-' + label);
      if (!block) {
        console.error('Assigned question is missing from the player:', label);
        return;
      }

      // Re-appending places the visible questions in the persisted assignment
      // order without changing any learnr exercise IDs. If the pool wrapper is
      // unavailable for any reason, still reveal the matching question in place.
      if (pool) pool.appendChild(block);
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
    window.Shiny.addCustomMessageHandler('assignment:clear', hideAll);
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

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() {
      hideAll();
      registerWhenReady();
    });
  } else {
    hideAll();
    registerWhenReady();
  }
})();
