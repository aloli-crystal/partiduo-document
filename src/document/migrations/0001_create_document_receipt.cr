# SPDX-License-Identifier: AGPL-3.0-or-later

# Boîte « Justificatifs à traiter » (ADR-005 D8), successeur des tables
# `document`, `acc_operation` et `document_supp` du schéma
# `noalyss_document`.
#
# Intégrité en base :
#
# * source, statut et nature contrôlés ;
# * un justificatif « rattaché » cite une écriture ou un document de la
#   Facturation ; un justificatif « à traiter » ou « écarté » n'en cite aucun ;
# * montant positif ou nul ;
# * les pièces jointes citées (original, version réduite, vignette, données
#   structurées) ne peuvent plus être effacées du socle (ADR-003 D5).
class Migration::Document::V0001 < Marten::Migration
  depends_on :core, "0002_core_referential"

  ATTACHMENT_COLUMNS = %w[original preview thumbnail data]

  CONSTRAINTS = [
    {<<-SQL, "SELECT 1"},
      ALTER TABLE document_receipt
        ADD CONSTRAINT document_receipt_source_check CHECK (source IN ('photo', 'file', 'einvoice')),
        ADD CONSTRAINT document_receipt_status_check CHECK (status IN ('to_process', 'attached', 'discarded')),
        ADD CONSTRAINT document_receipt_kind_check
          CHECK (kind IN ('', 'invoice', 'ticket', 'expense_report', 'other')),
        ADD CONSTRAINT document_receipt_amount_check CHECK (amount IS NULL OR amount >= 0),
        ADD CONSTRAINT document_receipt_link_check CHECK (
          (status = 'attached') = (entry_id IS NOT NULL OR invoice_id IS NOT NULL)
        )
      SQL
  ] + ATTACHMENT_COLUMNS.map do |name|
    {"ALTER TABLE document_receipt ADD CONSTRAINT document_receipt_#{name}_fk FOREIGN KEY (#{name}_attachment_id) " \
     "REFERENCES core_attachment (id)", "SELECT 1"}
  end

  def plan
    create_table :document_receipt do
      column :id, :big_int, primary_key: true, auto: true
      column :source, :string, max_size: 16
      column :status, :string, max_size: 16, default: "to_process", index: true
      column :supplier_name, :string, max_size: 255, default: ""
      column :supplier_card_id, :big_int, null: true
      column :supplier_code, :string, max_size: 40, default: ""
      column :amount, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :currency_code, :string, max_size: 3, default: ""
      column :document_date, :date, null: true
      column :kind, :string, max_size: 16, default: ""
      column :note, :text, default: ""
      column :reference, :string, max_size: 100, default: ""
      column :filename, :string, max_size: 255
      column :content_type, :string, max_size: 128
      column :byte_size, :big_int
      column :original_attachment_id, :big_int
      column :preview_attachment_id, :big_int, null: true
      column :thumbnail_attachment_id, :big_int, null: true
      column :data_attachment_id, :big_int, null: true
      column :sha256, :string, max_size: 64, index: true
      column :external_ref, :string, max_size: 255, null: true, unique: true
      column :entry_id, :big_int, null: true, index: true
      column :invoice_id, :big_int, null: true
      column :attached_at, :date_time, null: true
      column :attached_by_id, :big_int, null: true
      column :discarded_at, :date_time, null: true
      column :captured_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
