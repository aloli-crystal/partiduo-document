# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Cas limites, permissions, modules inactifs et intégrité en base de la boîte
# « Justificatifs à traiter » (lot E, testeur). Règles reprises de
# `noalyss_document` : `Document_Load::upload` (types admis, nom du
# fichier), `Document_Operation::warning_duplicate` (doublons : même
# fournisseur, même date, même montant, écriture courante exclue).

private alias Api = Document::Api
private alias Acc = Partiduo::Api::Accounting
private alias S = Document::SpecSupport
private alias Books = PartiduoUi::Books

private def details(**args) : Api::DetailsInput
  Api::DetailsInput.new(**args)
end

private def sql(query : String, *args) : Nil
  Marten::DB::Connection.default.open(&.exec(query, *args))
end

private def books : Nil
  PartiduoUi::Reference.provision("fr")
  PartiduoUi::Reference.fiscal_year(2026)
  S.activate
  PartiduoUi::Accounts.create
  Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
end

private def admin : Partiduo::Api::Actor
  Partiduo::Api::Auth.actor(PartiduoUi::Accounts.token)
end

private def purchase(receipt : Api::ReceiptView, amount : String = "86.40") : Acc::DocumentInput
  prefill = Api.purchase_prefill(admin, receipt.id)
  lines = prefill.lines.map do |line|
    Acc::DocumentLineInput.new(amount: line.amount, account: "603", vat_rate: line.vat_rate, vat_amount: line.vat_amount,
      label: line.label)
  end
  Acc::DocumentInput.new(ledger_id: prefill.ledger_id || raise("journal d'achats absent"), date: prefill.date,
    third_party: prefill.third_party, label: prefill.label, lines: lines)
end

private def received(receipt : Api::ReceiptView, amount : String = "86.40") : Acc::ReceivedInvoiceInput
  Acc::ReceivedInvoiceInput.new(document: purchase(receipt, amount), number: receipt.reference)
end

private def orange(amount : String = "86.40") : Api::ReceiptView
  S.capture(S::PDF, "FB-4471.pdf", details(supplier_code: "FOUR-ORANGE", amount: S.d(amount),
    date: S.date("2026-09-24"), reference: "FB-4471"))
end

describe "Justificatifs : règles, cas limites et intégrité (lot E)" do
  it "nettoie le nom du fichier déposé : sans chemin, sans contrôle, jamais vide" do
    S.activate
    S.capture(S::PNG, "C:\\Users\\moi\\Pictures\\IMG_0042.png").filename.should eq("IMG_0042.png")
    S.capture(S::PNG, "/var/mobile/../x/scan.png").filename.should eq("scan.png")
    S.capture(S::PNG, "blob").filename.should eq("justificatif.png")
    S.capture(S::PDF, "   ").filename.should eq("justificatif.pdf")
    S.capture(S::PNG, "ti\u0007cket\n.png").filename.should eq("ticket.png")
    long = S.capture(S::PNG, "#{"a" * 300}.png").filename
    long.size.should eq(200)
    long.should end_with(".png")
    # Le type vient du contenu, pas de l'extension annoncée.
    S.capture(S::PDF, "photo.jpg").content_type.should eq("application/pdf")
  end

  it "nomme les versions produites d'après l'original" do
    S.activate
    receipt = S.capture(S::HEIC, "IMG_0042.heic")
    Api.file(S.admin, receipt.id, "preview").filename.should eq("IMG_0042-preview.jpg")
    Api.file(S.admin, receipt.id, "thumbnail").content_type.should eq("image/jpeg")
    Api.file(S.admin, receipt.id, "original").content.should eq(S::HEIC)
    # Version inconnue ou absente : NotFound.
    expect_raises(Partiduo::Api::NotFound) { Api.file(S.admin, receipt.id, "data") }
    expect_raises(Partiduo::Api::NotFound) { Api.file(S.admin, receipt.id, "vignette") }
    expect_raises(Partiduo::Api::NotFound) { Api.file(S.admin, 999_999_i64) }
  end

  it "refuse les formats que NOALYSS n'admet pas non plus (GIF, XML en dépôt manuel)" do
    S.activate
    gif = "GIF89a\x01\x00\x01\x00".to_slice
    Api.check_capture(S.admin, Api::CaptureInput.new("a.gif", gif)).error_keys
      .should eq(["document.errors.receipt.content.unsupported"])
    # Le XML seul n'est admis que pour une facture reçue de la plateforme.
    Api.check_capture(S.admin, Api::CaptureInput.new("f.xml", S::XML)).error_keys
      .should eq(["document.errors.receipt.content.unsupported"])
    # Taille : la limite des pièces jointes du socle.
    big = Bytes.new(Api::MAX_BYTES + 1, 0_u8)
    big[0] = 0x25_u8
    Api.check_capture(S.admin, Api::CaptureInput.new("big.pdf", big)).error_keys
      .should eq(["document.errors.receipt.content.too_large"])
  end

  it "contrôle la source d'un dépôt dans le contrôle instantané comme à l'enregistrement" do
    S.activate
    input = Api::CaptureInput.new("t.png", S::PNG, source: "scanner")
    Api.capture(S.admin, input).error_keys.should eq(["document.errors.receipt.source.invalid"])
    Api.check_capture(S.admin, input).error_keys.should eq(["document.errors.receipt.source.invalid"])
    S.capture(S::PDF, "a.pdf", source: "photo").source.should eq("photo")
    S.capture(S::PNG, "a.png", source: "file").source.should eq("file")
  end

  it "borne le montant TTC : zéro admis, quatre décimales, seize chiffres entiers" do
    S.activate
    S.capture(details: details(amount: S.d("0"))).amount.should eq(S.d("0"))
    S.capture(details: details(amount: S.d("12.3456"))).amount.should eq(S.d("12.3456"))
    S.capture(details: details(amount: S.d("9999999999999999.9999"))).amount.should eq(S.d("9999999999999999.9999"))
    Api.check_details(S.admin, details(amount: S.d("10000000000000000"))).error_keys
      .should eq(["document.errors.receipt.amount.too_large"])
    Api.check_details(S.admin, details(amount: S.d("0.00001"))).error_keys
      .should eq(["document.errors.receipt.amount.too_precise"])
  end

  it "normalise les compléments : date sans heure, devise en capitales, textes sans blancs" do
    S.activate
    receipt = S.capture(details: details(date: Time.utc(2026, 9, 24, 23, 59, 59), currency_code: " usd ",
      supplier_name: "  Leroy Merlin  ", note: "  cheville  ", reference: "  F-1  ", kind: " ticket "))
    receipt.date.should eq(S.date("2026-09-24"))
    receipt.currency_code.should eq("USD")
    receipt.supplier_name.should eq("Leroy Merlin")
    receipt.note.should eq("cheville")
    receipt.reference.should eq("F-1")
    receipt.kind.should eq("ticket")
  end

  it "ne reconnaît la fiche du fournisseur que si l'acteur peut la lire ; le nom saisi prime" do
    books
    named = S.capture(details: details(supplier_code: "FOUR-ORANGE", supplier_name: "Orange (agence Tours)"))
    named.supplier_name.should eq("Orange (agence Tours)")
    named.supplier_code.should eq("FOUR-ORANGE")
    named.supplier_card_id.should_not be_nil
    blind = Partiduo::Api::Actor.user(9_i64, [Api::READ, Api::WRITE, Api::ATTACHMENT_WRITE])
    Api.check_details(blind, details(supplier_code: "FOUR-ORANGE")).error_keys
      .should eq(["document.errors.receipt.supplier_code.unknown"])
    # Retirer la fiche : les compléments sont remplacés en entier.
    Api.update_details(S.admin, named.id, details(supplier_name: "Orange")).value!.supplier_card_id.should be_nil
  end

  it "borne la pagination de la boîte et ignore un statut inconnu" do
    S.activate
    3.times { S.capture }
    Api.receipts(S.reader, Api::ReceiptQuery.new(limit: 0)).size.should eq(1)
    Api.receipts(S.reader, Api::ReceiptQuery.new(limit: 2, offset: -5)).size.should eq(2)
    Api.receipts(S.reader, Api::ReceiptQuery.new(offset: 10)).should be_empty
    Api.receipts(S.reader, Api::ReceiptQuery.new(status: "perdu")).should be_empty
    Api.count_receipts(S.reader, Api::ReceiptQuery.new(status: nil, search: "   ")).should eq(3)
  end

  it "réception : identifiant nettoyé et borné, nature gardée, doublon de contenu signalé" do
    S.activate
    system = Partiduo::Api::Actor.system
    first = Api.receive(system, Api::ReceiveInput.new("f.pdf", S::PDF, "  pa:7  ")).value!
    first.external_ref.should eq("pa:7")
    first.kind.should eq("invoice")
    Api.receive(system, Api::ReceiveInput.new("f.pdf", S::PNG, "pa:7")).value!.id.should eq(first.id)
    Api.receive(system, Api::ReceiveInput.new("f.pdf", S::PDF, "x" * 256)).error_keys
      .should eq(["document.errors.receipt.external_ref.too_long"])
    other = Api.receive(system, Api::ReceiveInput.new("t.pdf", S::PDF, "pa:8", details(kind: "other"))).value!
    other.kind.should eq("other")
    Api.duplicates(S.reader, other.id).receipts.map(&.id).should eq([first.id])
    Api.receive(system, Api::ReceiveInput.new("t.pdf", S::PDF, "pa:9", details(kind: "facture"))).error_keys
      .should eq(["document.errors.receipt.kind.invalid"])
  end

  it "ne propose pas en doublon l'écriture du justificatif lui-même (warning_duplicate, jr_internal <> courant)" do
    books
    receipt = orange
    entry = Acc.entry(admin, Api.post_purchase(admin, receipt.id, received(receipt)).value!.entry_id)
    Api.duplicates(admin, receipt.id).entries.should be_empty
    copy = orange
    Api.duplicates(admin, copy.id).entries.map(&.id).should eq([entry.id])
    # Autre montant ou autre date : pas de doublon d'écriture.
    Api.duplicates(admin, orange("86.41").id).entries.should be_empty
    # Une écriture extournée n'est plus un doublon.
    Acc.cancel_entry(admin, Acc::CancelEntryInput.new(entry.id)).success?.should be_true
    Api.duplicates(admin, copy.id).entries.should be_empty
    # Sans droit de lecture de la Comptabilité : les écritures ne sont pas consultées.
    Api.duplicates(S.reader, copy.id).entries.should be_empty
  end

  it "préremplit sans TVA déduite pour une autoliquidation ou un taux nul" do
    books
    receipt = orange("100")
    autoliquidation = Api.purchase_prefill(admin, receipt.id, "INTS").lines.first
    autoliquidation.amount.should eq(S.d("100"))
    autoliquidation.vat_amount.should be_nil
    autoliquidation.vat_rate.should eq("INTS")
    exempt = Api.purchase_prefill(admin, receipt.id, "FRANC").lines.first
    exempt.amount.should eq(S.d("100"))
    exempt.vat_rate.should eq("FRANC")
    normal = Api.purchase_prefill(admin, receipt.id).lines.first
    normal.amount.should eq(S.d("83.33"))
    normal.vat_amount.should eq(S.d("16.67"))
    # Code inconnu : aucune TVA proposée.
    unknown = Api.purchase_prefill(admin, receipt.id, "ZZZ").lines.first
    unknown.vat_rate.should be_nil
    unknown.amount.should eq(S.d("100"))
  end

  it "rattache par entry.posted un justificatif écarté, jamais par une extourne" do
    books
    receipt = orange
    Api.discard(admin, receipt.id).success?.should be_true
    Api.post_purchase(admin, receipt.id, received(receipt)).error_keys
      .should eq(["document.errors.receipt.status.not_to_process"])
    input = purchase(receipt).copy_with(source: "document:#{receipt.id}")
    entry = Acc.post_purchase(Partiduo::Api::Actor.system, input).value!
    attached = Api.receipt(admin, receipt.id)
    attached.status.should eq("attached")
    attached.discarded_at.should be_nil
    attached.entry_id.should eq(entry.id)
    # L'extourne reprend la source de l'écriture : elle ne rattache rien.
    Acc.cancel_entry(admin, Acc::CancelEntryInput.new(entry.id)).success?.should be_true
    Api.receipt(admin, receipt.id).status.should eq("to_process")
  end

  it "détache un justificatif rattaché sans toucher à l'écriture ; l'extourne ne vise que ses justificatifs" do
    books
    first = orange
    second = orange("12")
    entry = Acc.entry(admin, Api.post_purchase(admin, first.id, received(first)).value!.entry_id)
    other = Acc.entry(admin, Api.post_purchase(admin, second.id, received(second, "12")).value!.entry_id)
    third = S.capture
    Api.link_entry(admin, third.id, entry.id).success?.should be_true

    Api.reopen(admin, third.id).value!.entry_id.should be_nil
    Acc.entry(admin, entry.id).cancelled?.should be_false
    Api.link_entry(admin, third.id, entry.id).success?.should be_true

    Acc.cancel_entry(admin, Acc::CancelEntryInput.new(entry.id)).success?.should be_true
    Api.receipt(admin, first.id).to_process?.should be_true
    Api.receipt(admin, third.id).to_process?.should be_true
    Api.receipt(admin, second.id).entry_id.should eq(other.id)
  end

  it "saisit une facture reçue hors plateforme : contrôle de doublon commun (ADR-004 D9, D-DOC-012)" do
    books
    first = orange
    invoice = Api.post_purchase(admin, first.id, received(first)).value!
    invoice.origin.should eq(Acc::ReceptionOrigin::OffPlatform)
    supplier = Partiduo::Api::Cards.card_by_code(Partiduo::Api::Actor.system, "FOUR-ORANGE") || raise "fiche absente"
    Acc.received_invoice_duplicates(admin, Acc::DuplicateQuery.new(supplier.id, "fb 4471", S.d("86.40")))
      .map(&.id).should eq([invoice.id])
    # La même facture photographiée une seconde fois : refusée, et laissée à traiter.
    copy = orange
    result = Api.post_purchase(admin, copy.id, received(copy))
    result.error_keys.should eq(["accounting.errors.received_invoice.duplicate"])
    Api.check_purchase(admin, copy.id, received(copy)).error_keys.should eq(["accounting.errors.received_invoice.duplicate"])
    Api.receipt(admin, copy.id).to_process?.should be_true
  end

  it "renvoie une facture reçue par la plateforme vers l'écran de facturation électronique" do
    books
    receipt = Api.receive(Partiduo::Api::Actor.system, Api::ReceiveInput.new("f.pdf", S::PDF, "einvoicing:pa-1",
      details(supplier_code: "FOUR-ORANGE", amount: S.d("86.40"), date: S.date("2026-09-24"), reference: "FB-4471"))).value!
    receipt.source.should eq("einvoice")
    einvoice = ["document.errors.receipt.einvoice"]
    Api.post_purchase(admin, receipt.id, received(receipt)).error_keys.should eq(einvoice)
    Api.check_purchase(admin, receipt.id, received(receipt)).error_keys.should eq(einvoice)
    entry = Acc.post_purchase(Partiduo::Api::Actor.system, purchase(orange)).value!
    Api.link_entry(admin, receipt.id, entry.id).error_keys.should eq(einvoice)
    Api.link_invoice(admin, receipt.id, 1_i64).error_keys.should eq(einvoice)
    Api.receipt(admin, receipt.id).to_process?.should be_true
    Acc.count_entries(admin).should eq(1)
  end

  it "exige document.receipt.write pour modifier, sans exiger l'écriture des pièces jointes" do
    S.activate
    receipt = S.capture
    reader = S.reader
    expect_raises(Partiduo::Api::Forbidden) { Api.update_details(reader, receipt.id, details(note: "x")) }
    expect_raises(Partiduo::Api::Forbidden) { Api.check_details(reader, details) }
    expect_raises(Partiduo::Api::Forbidden) { Api.discard(reader, receipt.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.reopen(reader, receipt.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.link_entry(reader, receipt.id, 1_i64) }
    expect_raises(Partiduo::Api::Forbidden) { Api.link_invoice(reader, receipt.id, 1_i64) }
    expect_raises(Partiduo::Api::Forbidden) { Api.candidates(reader, receipt.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.check_capture(reader, Api::CaptureInput.new("t.png", S::PNG)) }
    writer = Partiduo::Api::Actor.user(4_i64, [Api::READ, Api::WRITE])
    Api.update_details(writer, receipt.id, details(note: "vu")).value!.note.should eq("vu")
    Api.discard(writer, receipt.id).success?.should be_true
    Api.reopen(writer, receipt.id).success?.should be_true
    # « Saisir l'écriture » exige en plus la permission de la Comptabilité.
    expect_raises(Partiduo::Api::Forbidden) { Api.purchase_prefill(writer, receipt.id) }
  end

  it "refuse tout le contrat quand l'extension est désactivée (ModuleDisabled)" do
    S.activate
    receipt = S.capture
    Partiduo::Api::Modules.deactivate(Partiduo::Api::Actor.system, Document::CODE).success?.should be_true
    actor = S.admin
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.capture(actor, Api::CaptureInput.new("t.png", S::PNG)) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.check_capture(actor, Api::CaptureInput.new("t.png", S::PNG)) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.update_details(actor, receipt.id, details) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.discard(actor, receipt.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.reopen(actor, receipt.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.receipt(actor, receipt.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.file(actor, receipt.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.duplicates(actor, receipt.id) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.count_receipts(actor) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.candidates(actor, receipt.id) }
    Api.pending_count(actor).should be_nil
  end

  it "garantit en base la source, la nature, le montant, les pièces jointes et l'unicité de la référence" do
    S.activate
    receipt = S.capture
    other = S.capture(S::PDF, "b.pdf")
    {
      "document_receipt_source_check" => "UPDATE document_receipt SET source = 'fax' WHERE id = $1",
      "document_receipt_kind_check"   => "UPDATE document_receipt SET kind = 'facture' WHERE id = $1",
      "document_receipt_amount_check" => "UPDATE document_receipt SET amount = -0.01 WHERE id = $1",
      "document_receipt_link_check"   => "UPDATE document_receipt SET entry_id = 1 WHERE id = $1",
      "document_receipt_original_fk"  => "UPDATE document_receipt SET original_attachment_id = 999999 WHERE id = $1",
      "document_receipt_thumbnail_fk" => "UPDATE document_receipt SET thumbnail_attachment_id = 999999 WHERE id = $1",
    }.each do |constraint, query|
      expect_raises(Exception, /#{constraint}/) { sql(query, receipt.id) }
    end
    sql("UPDATE document_receipt SET external_ref = 'pa:1' WHERE id = $1", receipt.id)
    expect_raises(Exception, /unique|duplicate/i) do
      sql("UPDATE document_receipt SET external_ref = 'pa:1' WHERE id = $1", other.id)
    end
    # Un justificatif rattaché ne peut perdre son écriture sans changer de statut.
    sql("UPDATE document_receipt SET status = 'attached', entry_id = 1 WHERE id = $1", other.id)
    expect_raises(Exception, /document_receipt_link_check/) do
      sql("UPDATE document_receipt SET entry_id = NULL WHERE id = $1", other.id)
    end
  end
end
