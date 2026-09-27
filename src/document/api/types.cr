# SPDX-License-Identifier: AGPL-3.0-or-later

module Document
  module Api
    # Sources d'un justificatif : prise de vue, fichier déposé, facture reçue
    # par la plateforme agréée (ADR-004). Libellé : `document.sources.<code>`.
    SOURCES = %w[photo file einvoice]

    # Statuts (ADR-005 D8). Libellé : `document.statuses.<code>`.
    STATUSES = %w[to_process attached discarded]

    # Natures (compléments facultatifs). Libellé : `document.kinds.<code>`.
    KINDS = %w[invoice ticket expense_report other]

    # Versions d'un fichier : l'original, et celles que produit le serveur.
    VARIANTS = %w[original preview thumbnail data]

    # Compléments facultatifs d'un justificatif (ADR-005 D8) : rien n'est
    # obligatoire. `supplier_code` : quick code d'une fiche du socle (le nom
    # de la fiche remplace alors `supplier_name` s'il est vide) ; `amount` :
    # montant TTC, positif ou nul, quatre décimales au plus ; `kind` : une
    # des `KINDS` ou vide ; `currency_code` : vide pour la devise de tenue.
    record DetailsInput,
      supplier_name : String = "",
      supplier_code : String? = nil,
      amount : BigDecimal? = nil,
      currency_code : String = "",
      date : Time? = nil,
      kind : String = "",
      note : String = "",
      reference : String = ""

    # Justificatif photographié ou déposé : le fichier (JPEG, PNG, HEIC, PDF ;
    # type reconnu au contenu), sa source (`photo` ou `file` ; `nil` : `photo`
    # pour une image, `file` pour un PDF, comme la maquette) et les
    # compléments.
    record CaptureInput,
      filename : String,
      content : Bytes,
      source : String? = nil,
      details : DetailsInput = DetailsInput.new

    # Facture reçue par la plateforme agréée (API publique pour
    # `partiduo-einvoicing`, ADR-004 D3, D9) : le fichier lisible (PDF,
    # Factur-X compris, ou image ; à défaut le XML lui-même), les données
    # structurées facultatives (XML UBL ou CII), et `external_ref`,
    # identifiant de la facture chez la plateforme, qui rend la réception
    # idempotente.
    record ReceiveInput,
      filename : String,
      content : Bytes,
      external_ref : String,
      details : DetailsInput = DetailsInput.new,
      data_filename : String? = nil,
      data : Bytes? = nil

    # Critères de la boîte : statut (tous si `nil`), source, texte cherché
    # dans le fournisseur, la note, la référence et le nom du fichier.
    record ReceiptQuery,
      status : String? = "to_process",
      source : String? = nil,
      search : String? = nil,
      limit : Int32 = 100,
      offset : Int32 = 0

    record ReceiptView,
      id : Int64,
      source : String,
      status : String,
      supplier_name : String,
      supplier_card_id : Int64?,
      supplier_code : String,
      amount : BigDecimal?,
      currency_code : String,
      date : Time?,
      kind : String,
      note : String,
      reference : String,
      filename : String,
      content_type : String,
      byte_size : Int64,
      original_attachment_id : Int64,
      preview_attachment_id : Int64?,
      thumbnail_attachment_id : Int64?,
      data_attachment_id : Int64?,
      sha256 : String,
      external_ref : String?,
      entry_id : Int64?,
      invoice_id : Int64?,
      attached_at : Time?,
      attached_by_id : Int64?,
      discarded_at : Time?,
      captured_by_id : Int64?,
      created_at : Time do
      def to_process? : Bool
        status == "to_process"
      end

      def attached? : Bool
        status == "attached"
      end

      def discarded? : Bool
        status == "discarded"
      end

      def pdf? : Bool
        content_type == "application/pdf"
      end

      # Un aperçu (version réduite) a été produit par le serveur.
      def preview? : Bool
        !preview_attachment_id.nil?
      end

      # Référence de l'écriture produite depuis ce justificatif (`source` de
      # `Partiduo::Api::Accounting::EntryInput`).
      def entry_source : String
        "#{Document::Api::SOURCE_PREFIX}#{id}"
      end
    end

    # Nombre de justificatifs par statut (menu, tableau de bord, onglets).
    record CountsView, to_process : Int64, attached : Int64, discarded : Int64

    # Fichier d'un justificatif, à servir tel quel.
    record FileView, filename : String, content_type : String, content : Bytes

    # Écriture ou document de la Facturation auquel rattacher un justificatif.
    # `kind` : `entry` ou `invoice`.
    record CandidateView,
      kind : String,
      id : Int64,
      reference : String,
      label : String,
      date : Time,
      amount : BigDecimal,
      third_party : String?

    # Doublons possibles (ADR-004 D9) : autres justificatifs de même contenu,
    # ou du même fournisseur, à la même date et au même montant ; écritures
    # d'achat déjà enregistrées du même fournisseur, même date, même montant
    # (`warning_duplicate` de NOALYSS).
    record DuplicatesView, receipts : Array(ReceiptView), entries : Array(CandidateView) do
      def found? : Bool
        !receipts.empty? || !entries.empty?
      end
    end

    # Ligne préremplie d'une écriture d'achat.
    record PrefillLineView,
      amount : BigDecimal,
      vat_rate : String?,
      vat_amount : BigDecimal?,
      label : String

    # Écriture d'achat préremplie depuis un justificatif (« Saisir
    # l'écriture », ADR-005 D8) : journal d'achats proposé (le premier où
    # l'acteur écrit), date, fournisseur, libellé, pièce, une ligne hors taxe
    # déduite du montant TTC et du taux choisi.
    record PrefillView,
      ledger_id : Int64?,
      date : Time,
      third_party : String,
      label : String,
      lines : Array(PrefillLineView),
      amount_including_vat : BigDecimal?
  end
end
