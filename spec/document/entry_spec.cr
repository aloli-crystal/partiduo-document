# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Document::Api
private alias Acc = Partiduo::Api::Accounting
private alias Inv = Partiduo::Api::Invoicing
private alias S = Document::SpecSupport
private alias Books = PartiduoUi::Books

# Dossier FR provisionné (plan, journaux, taux), exercice 2026, fournisseur,
# extension active.
private def books : Partiduo::Api::Cards::CardView
  PartiduoUi::Reference.provision("fr")
  PartiduoUi::Reference.fiscal_year(2026)
  S.activate
  PartiduoUi::Accounts.create
  Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
end

# Administrateur réel : les droits par journal se lisent sur l'utilisateur.
private def admin : Partiduo::Api::Actor
  Partiduo::Api::Auth.actor(PartiduoUi::Accounts.token)
end

private def orange_receipt : Api::ReceiptView
  S.capture(S::PDF, "FB-4471.pdf", Api::DetailsInput.new(supplier_code: "FOUR-ORANGE", amount: S.d("86.40"),
    date: S.date("2026-09-24"), reference: "FB-2026-0918-4471", kind: "invoice"))
end

private def purchase(prefill : Api::PrefillView, account : String = "603") : Acc::DocumentInput
  lines = prefill.lines.map do |line|
    Acc::DocumentLineInput.new(amount: line.amount, account: account, vat_rate: line.vat_rate, vat_amount: line.vat_amount,
      label: line.label)
  end
  Acc::DocumentInput.new(ledger_id: prefill.ledger_id || raise("journal d'achats absent"), date: prefill.date,
    third_party: prefill.third_party, label: prefill.label, lines: lines)
end

describe "Justificatifs : « Saisir l'écriture » et rattachement (ADR-005 D8)" do
  it "préremplit une écriture d'achat : journal, date, fournisseur, taux normal, hors taxe déduit du TTC" do
    books
    receipt = orange_receipt
    prefill = Api.purchase_prefill(admin, receipt.id)
    prefill.ledger_id.should eq(Books.ledger("A01").id)
    prefill.date.should eq(S.date("2026-09-24"))
    prefill.third_party.should eq("FOUR-ORANGE")
    prefill.label.should eq("Orange Business · FB-2026-0918-4471")
    prefill.amount_including_vat.should eq(S.d("86.40"))
    prefill.lines.size.should eq(1)
    line = prefill.lines.first
    line.vat_rate.should eq("NOR")
    line.amount.should eq(S.d("72"))
    line.vat_amount.should eq(S.d("14.40"))

    without = Api.purchase_prefill(admin, receipt.id, "").lines.first
    without.amount.should eq(S.d("86.40"))
    without.vat_rate.should be_nil
    reduced = Api.purchase_prefill(admin, receipt.id, "INT").lines.first
    (reduced.amount + (reduced.vat_amount || 0)).should eq(S.d("86.40"))

    blank = S.capture
    empty = Api.purchase_prefill(admin, blank.id)
    empty.third_party.should eq("")
    empty.lines.first.amount.should eq(S.d("0"))
    empty.label.should eq("ticket.png")
  end

  it "enregistre l'écriture avec l'original en pièce jointe ; le justificatif passe en « Rattaché »" do
    books
    receipt = orange_receipt
    input = purchase(Api.purchase_prefill(admin, receipt.id))
    draft = Api.check_purchase(admin, receipt.id, input).value!
    draft.total_including_vat.should eq(S.d("86.40"))
    Api.receipt(admin, receipt.id).to_process?.should be_true

    entry = Api.post_purchase(admin, receipt.id, input).value!
    entry.attachment_id.should eq(receipt.original_attachment_id)
    entry.source.should eq("document:#{receipt.id}")
    entry.amount.should eq(S.d("86.40"))

    attached = Api.receipt(admin, receipt.id)
    attached.status.should eq("attached")
    attached.entry_id.should eq(entry.id)
    attached.attached_by_id.should eq(admin.user_id)
    Api.pending_count(S.reader).should eq(0)
    Api.counts(S.reader).attached.should eq(1)

    # Une seconde saisie du même justificatif est refusée.
    Api.post_purchase(admin, receipt.id, input).error_keys.should eq(["document.errors.receipt.status.not_to_process"])
    Acc.entries(admin, Acc::EntryQuery.new(source: "document:#{receipt.id}")).size.should eq(1)
  end

  it "laisse le justificatif à traiter si l'écriture est refusée" do
    books
    receipt = orange_receipt
    input = purchase(Api.purchase_prefill(admin, receipt.id)).copy_with(third_party: "INCONNU")
    Api.post_purchase(admin, receipt.id, input).failure?.should be_true
    Api.receipt(admin, receipt.id).to_process?.should be_true
  end

  it "revient « À traiter » quand l'écriture est extournée" do
    books
    receipt = orange_receipt
    entry = Api.post_purchase(admin, receipt.id, purchase(Api.purchase_prefill(admin, receipt.id))).value!
    Acc.cancel_entry(admin, Acc::CancelEntryInput.new(entry.id)).success?.should be_true
    reopened = Api.receipt(admin, receipt.id)
    reopened.status.should eq("to_process")
    reopened.entry_id.should be_nil
  end

  it "passe en « Rattaché » quand une écriture saisie ailleurs cite le justificatif (entry.posted)" do
    books
    receipt = orange_receipt
    input = purchase(Api.purchase_prefill(admin, receipt.id)).copy_with(source: "document:#{receipt.id}")
    entry = Acc.post_purchase(Partiduo::Api::Actor.system, input).value!
    Api.receipt(admin, receipt.id).entry_id.should eq(entry.id)
    # Source d'un autre émetteur, ou justificatif inconnu : rien.
    Acc.post_purchase(Partiduo::Api::Actor.system, input.copy_with(source: "document:999999")).success?.should be_true
    Acc.post_purchase(Partiduo::Api::Actor.system, input.copy_with(source: "invoice:1")).success?.should be_true
    Document::Receipt.filter(status: "attached").count.should eq(1)
  end

  it "rattache à une écriture existante, signale une écriture déjà saisie et la propose" do
    books
    receipt = orange_receipt
    other = S.capture(S.jpeg, "copie.jpg", Api::DetailsInput.new(supplier_code: "FOUR-ORANGE", amount: S.d("86.40"),
      date: S.date("2026-09-24")))
    entry = Acc.post_purchase(Partiduo::Api::Actor.system, purchase(Api.purchase_prefill(admin, receipt.id))).value!

    duplicates = Api.duplicates(admin, other.id)
    duplicates.entries.map(&.id).should eq([entry.id])
    duplicates.receipts.map(&.id).should eq([receipt.id])

    candidates = Api.candidates(admin, other.id)
    candidates.map { |candidate| {candidate.kind, candidate.id} }.should eq([{"entry", entry.id}])
    candidates.first.third_party.should eq("FOUR-ORANGE")
    Api.candidates(admin, other.id, entry.receipt || "").map(&.id).should eq([entry.id])
    Api.candidates(admin, other.id, "introuvable").should be_empty

    linked = Api.link_entry(admin, other.id, entry.id).value!
    linked.status.should eq("attached")
    linked.entry_id.should eq(entry.id)
    Api.link_entry(admin, other.id, entry.id).error_keys.should eq(["document.errors.receipt.status.not_to_process"])

    third = S.capture
    Api.link_entry(admin, third.id, 999_999_i64).error_keys.should eq(["document.errors.receipt.entry_id.unknown"])
    reversal = Acc.cancel_entry(admin, Acc::CancelEntryInput.new(entry.id)).value!
    Api.link_entry(admin, third.id, entry.id).error_keys.should eq(["document.errors.receipt.entry_id.cancelled"])
    Api.link_entry(admin, third.id, reversal.id).error_keys.should eq(["document.errors.receipt.entry_id.cancelled"])
    # Détacher : le justificatif revient à traiter.
    Api.reopen(admin, third.id).error_keys.should eq(["document.errors.receipt.status.already_to_process"])
  end

  it "rattache à une facture émise de la Facturation" do
    books
    customer = Books.card("CUSTOMER", "Atelier Morel", "CLI-MOREL")
    rate = Partiduo::Api::Vat.rate_by_code(Books.system, "NOR") || raise "taux NOR absent"
    product = Partiduo::Api::Cards.create_card(Books.system, Partiduo::Api::Cards::CardInput.new(
      category_id: PartiduoUi::Reference.category("SALE").id, name: "Conseil", code: "CONSEIL", unit_code: "HUR",
      sale_price: S.d("80"), vat_rate_id: rate.id)).value!
    draft = Inv.create_document(Books.system, Inv::DocumentInput.new(kind: "invoice", customer_card_id: customer.id,
      lines: [Inv::LineInput.new(item_card_id: product.id, quantity: S.d("1"))], due_date: S.date("2026-10-20"))).value!
    invoice = Inv.issue(Books.system, draft.id, Inv::IssueInput.new(S.date("2026-09-20"))).value!

    receipt = S.capture
    found = Api.candidates(admin, receipt.id, invoice.number || "")
    found.select(&.kind.==("invoice")).map(&.id).should eq([invoice.id])
    Api.link_invoice(admin, receipt.id, draft.id).value!.invoice_id.should eq(invoice.id)
    unissued = Inv.create_document(Books.system, Inv::DocumentInput.new(kind: "invoice", customer_card_id: customer.id,
      lines: [Inv::LineInput.new(item_card_id: product.id, quantity: S.d("1"))])).value!
    Api.link_invoice(admin, S.capture.id, unissued.id).error_keys.should eq(["document.errors.receipt.invoice_id.unknown"])
  end

  it "exige la Comptabilité pour saisir, la Facturation pour rattacher une facture" do
    with_active_modules("invoicing") do
      PartiduoUi::Reference.provision("fr", ["invoicing"])
      S.activate
      PartiduoUi::Accounts.create
      receipt = S.capture
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.purchase_prefill(admin, receipt.id) }
      Api.link_entry(admin, receipt.id, 1_i64).error_keys.should eq(["document.errors.receipt.module_inactive"])
      Api.candidates(admin, receipt.id).should be_empty
    end
    with_active_modules("accounting,invoicing") do
      Partiduo::Api::Modules.activate(Partiduo::Api::Actor.system, "accounting")
      Partiduo::Api::Modules.deactivate(Partiduo::Api::Actor.system, "invoicing").success?.should be_true
      receipt = S.capture
      Api.link_invoice(admin, receipt.id, 1_i64).error_keys.should eq(["document.errors.receipt.module_inactive"])
    end
  end
end
