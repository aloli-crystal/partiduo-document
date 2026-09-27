# SPDX-License-Identifier: AGPL-3.0-or-later

# Manifeste de l'extension DOCUMENT (ADR-003 D2, `doc/api/modules.adoc` du
# cœur), successeur des deux entrées de `noalyss_document` : NDER (saisie) et
# NDC (chargement depuis un téléphone), réunies dans une seule boîte
# « Justificatifs à traiter » (ADR-005 D8).
#
# * Permissions : `document.receipt.read` (voir la boîte et les fichiers),
#   `document.receipt.write` (déposer, compléter, écarter, rattacher,
#   saisir l'écriture). Le stockage des fichiers relève du socle : il exige
#   en plus `core.attachment.write` (dépôt) et `core.attachment.read`
#   (lecture), comme toute pièce jointe (DECISIONS D-DOC-004).
# * Menu `DOCUMENT_INBOX` sous la rubrique `ENTRY` (« Saisie ») du socle,
#   comme dans la maquette ; route `document:index`, montée par l'interface
#   sous `/ext/DOCUMENT/`.
# * Aucune dépendance : la boîte fonctionne sur le socle seul (réception des
#   factures électroniques par `partiduo-einvoicing`, qui dépend de DOCUMENT) ;
#   « Saisir l'écriture » exige la Comptabilité, le rattachement à une
#   facture la Facturation, vérifiées à l'appel (D-DOC-002).
# * `entry.posted` : une écriture enregistrée depuis un justificatif (source
#   `document:<id>`) le fait passer en « Rattaché » ; `entry.cancelled` : un
#   justificatif rattaché à une écriture extournée revient « À traiter ».
Partiduo::Modules.register do
  code "DOCUMENT"
  name "document.module.name"
  version "0.1.0"
  requires_core "~> 0.1"

  permission "document.receipt.read"
  permission "document.receipt.write"

  menu "DOCUMENT_INBOX", parent: "ENTRY", order: 5, route: "document:index", permission: "document.receipt.read"

  ui "bulma", path: "ui/bulma"

  on("entry.posted") { |event| Document::Linking.entry_posted(event) }
  on("entry.cancelled") { |event| Document::Linking.entry_cancelled(event) }
end
