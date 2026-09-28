# SPDX-License-Identifier: AGPL-3.0-or-later

module Document
  # Justificatif de la boîte « Justificatifs à traiter » (ADR-005 D8),
  # successeur des tables `document` et `acc_operation` (NDER) du module de
  # justificatifs d'origine.
  # Interne : on le lit et on l'écrit par `Document::Api`.
  #
  # Les fichiers sont des pièces jointes du socle (`core_attachment`, ADR-006
  # D1) : l'original tel quel, et, produites par le serveur, une vignette et
  # une version réduite (JPEG). Les colonnes `*_attachment_id` portent une clé
  # étrangère vers `core_attachment` posée par la migration (ADR-003 D5) :
  # une pièce citée par un justificatif ne peut pas être effacée.
  #
  # `entry_id` (Comptabilité) et `invoice_id` (Facturation) sont des
  # identifiants lus par `Partiduo::Api`, sans clé étrangère : l'extension ne
  # pose pas de contrainte sur une table d'un module qu'elle ne déclare pas
  # (D-DOC-002).
  class Receipt < Marten::Model
    field :id, :big_int, primary_key: true, auto: true

    # `photo` (prise de vue), `file` (fichier déposé), `einvoice` (facture
    # reçue par la plateforme agréée, ADR-004).
    field :source, :string, max_size: 16
    # `to_process`, `attached`, `discarded` (contrainte en base).
    field :status, :string, max_size: 16, default: "to_process", index: true

    # Compléments facultatifs (ADR-005 D8) : fournisseur (nom libre et, s'il
    # est reconnu, sa fiche du socle), montant TTC, date, nature, note.
    field :supplier_name, :string, max_size: 255, blank: true, default: ""
    field :supplier_card_id, :big_int, blank: true, null: true
    # Quick code de la fiche, relevé au rattachement de la fiche.
    field :supplier_code, :string, max_size: 40, blank: true, default: ""
    field :amount, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    # Devise du montant ; vide : devise de tenue.
    field :currency_code, :string, max_size: 3, blank: true, default: ""
    field :document_date, :date, blank: true, null: true
    # `invoice`, `ticket`, `expense_report`, `other` ; vide : non précisée.
    field :kind, :string, max_size: 16, blank: true, default: ""
    field :note, :text, blank: true, default: ""
    # Numéro de la facture (factures électroniques, saisie manuelle).
    field :reference, :string, max_size: 100, blank: true, default: ""

    # Pièces jointes du socle. Nom, type et taille de l'original sont
    # recopiés pour la liste (lue sans la permission des pièces jointes).
    field :filename, :string, max_size: 255
    field :content_type, :string, max_size: 128
    field :byte_size, :big_int
    field :original_attachment_id, :big_int
    field :preview_attachment_id, :big_int, blank: true, null: true
    field :thumbnail_attachment_id, :big_int, blank: true, null: true
    # Données structurées d'une facture électronique (UBL, CII).
    field :data_attachment_id, :big_int, blank: true, null: true
    # Empreinte de l'original, pour la détection des doublons.
    field :sha256, :string, max_size: 64, index: true

    # Référence de l'émetteur externe (plateforme agréée) : unique, rend la
    # réception idempotente.
    field :external_ref, :string, max_size: 255, blank: true, null: true, unique: true

    # Rattachement : écriture de la Comptabilité ou document de la Facturation.
    field :entry_id, :big_int, blank: true, null: true, index: true
    field :invoice_id, :big_int, blank: true, null: true
    field :attached_at, :date_time, blank: true, null: true
    field :attached_by_id, :big_int, blank: true, null: true
    field :discarded_at, :date_time, blank: true, null: true

    field :captured_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
