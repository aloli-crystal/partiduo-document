// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Liaison au navigateur de la boîte « Justificatifs à traiter » (extension
// DOCUMENT, ADR-005 D8), écrite à la main comme ui/js/shell.js
// (DECISIONS D-UI-005, D-DOC-008) : aucune règle métier. Sans ce script, le
// formulaire multipart s'envoie tel quel.
//
// * Les compléments n'apparaissent qu'une fois la photo prise ou le fichier
//   choisi (maquette), avec un aperçu local de l'image (pas pour HEIC ni PDF,
//   que le navigateur ne sait pas toujours afficher : le nom suffit).
// * Glisser-déposer sur ordinateur : le fichier déposé devient celui du
//   champ, puis même parcours.
(function () {
  "use strict";

  function mount(form) {
    if (form.getAttribute("data-doc-mounted")) return;
    form.setAttribute("data-doc-mounted", "1");
    var input = form.querySelector("input[type=file]");
    var quick = form.querySelector("[data-doc-quick]");
    var drop = form.querySelector("[data-doc-drop]");
    var preview = form.querySelector("[data-doc-preview]");
    var image = form.querySelector("[data-doc-preview-img]");
    var name = form.querySelector("[data-doc-preview-name]");
    var hasErrors = form.querySelector("[aria-invalid=true]");
    var objectUrl = null;
    if (!input || !quick) return;
    if (!hasErrors) quick.hidden = true;

    function show(file) {
      if (!file) return;
      if (objectUrl) { URL.revokeObjectURL(objectUrl); objectUrl = null; }
      var displayable = /^image\/(jpeg|png|gif|webp)$/.test(file.type);
      if (preview && image) {
        preview.hidden = false;
        if (displayable) {
          objectUrl = URL.createObjectURL(file);
          image.src = objectUrl;
          image.hidden = false;
        } else {
          image.removeAttribute("src");
          image.hidden = true;
        }
      }
      if (name) name.textContent = file.name || "";
      quick.hidden = false;
      var first = quick.querySelector("input:not([type=hidden]), select");
      if (first) first.focus();
    }

    input.addEventListener("change", function () { show(input.files && input.files[0]); });

    if (drop) {
      ["dragenter", "dragover"].forEach(function (type) {
        drop.addEventListener(type, function (event) { event.preventDefault(); drop.classList.add("is-over"); });
      });
      ["dragleave", "drop"].forEach(function (type) {
        drop.addEventListener(type, function (event) { event.preventDefault(); drop.classList.remove("is-over"); });
      });
      drop.addEventListener("drop", function (event) {
        var files = event.dataTransfer && event.dataTransfer.files;
        if (!files || !files.length) return;
        try {
          var transfer = new DataTransfer();
          transfer.items.add(files[0]);
          input.files = transfer.files;
        } catch (e) {
          input.files = files;
        }
        show(files[0]);
      });
    }

    var cancel = form.querySelector("[data-doc-cancel]");
    if (cancel) {
      cancel.addEventListener("click", function () {
        if (objectUrl) { URL.revokeObjectURL(objectUrl); objectUrl = null; }
        if (preview) preview.hidden = true;
        quick.hidden = true;
      });
    }
  }

  function boot(root) {
    (root || document).querySelectorAll("form[data-doc-capture]").forEach(mount);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { boot(); });
  } else {
    boot();
  }
  document.addEventListener("htmx:load", function (event) { boot(event.target); });
})();
