# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Api = Document::Api
private alias Acc = Partiduo::Api::Accounting
private alias S = Document::SpecSupport
private alias Books = PartiduoUi::Books

# Dossier FR, exercice 2026, administrateur connecté, extension active.
private def signed_in : PartiduoUi::Browser
  browser = Books.admin
  S.activate
  browser
end

describe "Boîte « Justificatifs à traiter » sous /ext/DOCUMENT/ (ADR-005 D8)" do
  it "est montée sous le code de l'extension, avec ses permissions" do
    Marten.routes.reverse("document:index").should eq("/ext/DOCUMENT/")
    Marten.routes.reverse("document:show", id: 4).should eq("/ext/DOCUMENT/4")
    mount = PartiduoUi::Extensions["DOCUMENT"]? || raise("interface non montée")
    mount.permission.should eq("document.receipt.read")
    mount.permission_for("document:capture").should eq("document.receipt.write")
    mount.permission_for("document:entry").should eq("document.receipt.write")
    mount.permission_for("document:file").should eq("document.receipt.read")
  end

  it "n'existe pas tant que l'extension est inactive (404) et renvoie un anonyme vers la connexion" do
    browser = Books.admin
    browser.get("/ext/DOCUMENT/").status.should eq(404)
    S.activate
    response = PartiduoUi::Browser.new.get("/ext/DOCUMENT/")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fext%2FDOCUMENT%2F")
  end

  it "affiche la prise de vue (appareil photo du téléphone), le dépôt et les compléments" do
    browser = signed_in
    page = browser.get("/ext/DOCUMENT/")
    page.status.should eq(200)
    html = page.html
    html.should contain("<h1>Justificatifs à traiter")
    html.should contain("Photographier un justificatif")
    html.should contain(%(accept="image/*,application/pdf" capture="environment"))
    html.should contain(%(enctype="multipart/form-data"))
    html.should contain("ou déposez ici une photo ou un PDF")
    html.should contain(%(name="supplier"))
    html.should contain(%(name="amount" value="" inputmode="decimal"))
    html.should contain("Mettre en attente")
    html.should contain("document/js/receipts.js")
    html.should contain("Rien à afficher.")
    html.should contain("Une photo est un justificatif de travail")
    # Menu « Saisie » : entrée de l'extension, sans compteur tant qu'il est nul.
    html.should contain(%(href="/ext/DOCUMENT/"))
    html.should_not contain(%(data-pd-count="DOCUMENT_INBOX"))
  end

  it "dépose une photo avec ses compléments ; le compteur du menu et du tableau de bord suit" do
    browser = signed_in
    supplier = Books.card("SUPPLIER", "Station Total Tours Nord", "FOUR-TOTAL")
    response = S.upload(browser, "/ext/DOCUMENT/capture",
      {"supplier" => "FOUR-TOTAL · Station Total Tours Nord", "amount" => "68,52", "date" => "2026-09-25",
       "kind" => "ticket", "reference" => "", "note" => "Carburant"}, {"file", "IMG_1204.JPG", S.jpeg})
    response.status.should eq(302)
    response.headers["Location"].should eq("/ext/DOCUMENT/")
    receipt = Api.receipts(S.admin).first
    receipt.source.should eq("photo")
    receipt.supplier_card_id.should eq(supplier.id)
    receipt.amount.should eq(S.d("68.52"))
    receipt.date.should eq(S.date("2026-09-25"))
    receipt.kind.should eq("ticket")
    receipt.note.should eq("Carburant")

    html = browser.get("/ext/DOCUMENT/").html
    html.should contain("Justificatif mis en attente.")
    html.should contain("Station Total Tours Nord")
    html.should contain("68,52")
    html.should contain(%(<span class="pd-count" data-pd-count="DOCUMENT_INBOX">1</span>))
    html.should contain(%(src="/ext/DOCUMENT/#{receipt.id}/file/thumbnail"))
    html.should contain("Saisir l'écriture")
    html.should contain("À traiter <span class=\"pd-doc-n\">(1)</span>")

    dashboard = browser.get("/").html
    dashboard.should contain("1 justificatif à traiter")
    S.capture
    browser.get("/").html.should contain("2 justificatifs à traiter")
  end

  it "refuse un dépôt sans fichier, illisible ou d'un format inconnu, et garde la saisie" do
    browser = signed_in
    response = S.upload(browser, "/ext/DOCUMENT/capture", {"supplier" => "Leroy Merlin", "amount" => "12"}, nil)
    response.status.should eq(422)
    response.html.should contain("Choisissez une photo ou un fichier.")
    response.html.should contain(%(value="Leroy Merlin"))
    response = S.upload(browser, "/ext/DOCUMENT/capture", {"amount" => "douze"}, {"file", "a.png", S::PNG})
    response.status.should eq(422)
    response.html.should contain("Montant illisible.")
    response = S.upload(browser, "/ext/DOCUMENT/capture", {"amount" => ""}, {"file", "notes.txt", "bonjour".to_slice})
    response.status.should eq(422)
    response.html.should contain("Format non pris en charge")
    Document::Receipt.all.count.should eq(0)
  end

  it "consulte un justificatif : image, compléments modifiables, écarter et remettre à traiter" do
    browser = signed_in
    receipt = S.capture(S.jpeg, "note.jpg", Api::DetailsInput.new(supplier_name: "Brasserie du Vieux Tours"))
    page = browser.get("/ext/DOCUMENT/#{receipt.id}").html
    page.should contain(%(src="/ext/DOCUMENT/#{receipt.id}/file/preview"))
    page.should contain(%(href="/ext/DOCUMENT/#{receipt.id}/file/original?download=1"))
    page.should contain("Brasserie du Vieux Tours")
    page.should contain("Saisir l'écriture")
    page.should contain("Rattacher")

    response = browser.post("/ext/DOCUMENT/#{receipt.id}/details", {"supplier" => "Brasserie", "amount" => "42,50",
                                                                    "date" => "2026-09-26", "kind" => "expense_report", "reference" => "", "note" => "Déjeuner client"})
    response.status.should eq(302)
    Api.receipt(S.admin, receipt.id).amount.should eq(S.d("42.50"))
    browser.post("/ext/DOCUMENT/#{receipt.id}/details", {"supplier" => "", "amount" => "-3", "date" => "", "kind" => "",
                                                         "reference" => "", "note" => ""}).html.should contain("Le montant ne peut pas être négatif.")

    browser.post("/ext/DOCUMENT/#{receipt.id}/discard").status.should eq(302)
    browser.get("/ext/DOCUMENT/#{receipt.id}").html.should contain("Justificatif écarté.")
    browser.get("/ext/DOCUMENT/?status=discarded").html.should contain("Brasserie")
    browser.post("/ext/DOCUMENT/#{receipt.id}/reopen").status.should eq(302)
    Api.receipt(S.admin, receipt.id).to_process?.should be_true
  end

  it "sert l'original tel quel et les versions produites par le serveur" do
    browser = signed_in
    receipt = S.capture(S::PDF, "facture.pdf")
    original = browser.get("/ext/DOCUMENT/#{receipt.id}/file/original")
    original.status.should eq(200)
    original.content_type.should eq("application/pdf")
    original.content.to_slice.should eq(S::PDF)
    original.headers["Content-Disposition"].should eq(%(inline; filename="facture.pdf"))
    original.headers["X-Content-Type-Options"].should eq("nosniff")
    browser.get("/ext/DOCUMENT/#{receipt.id}/file/original?download=1").headers["Content-Disposition"]
      .should eq(%(attachment; filename="facture.pdf"))
    browser.get("/ext/DOCUMENT/#{receipt.id}/file/thumbnail").content_type.should eq("image/jpeg")
    browser.get("/ext/DOCUMENT/#{receipt.id}/file/data").status.should eq(404)
    browser.get("/ext/DOCUMENT/#{receipt.id}/file/secret").status.should eq(404)
    browser.get("/ext/DOCUMENT/999999/file/original").status.should eq(404)
  end

  it "saisit l'écriture avec l'image à côté ; le justificatif passe en « Rattaché »" do
    browser = signed_in
    Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
    receipt = S.capture(S::PDF, "FB-4471.pdf", Api::DetailsInput.new(supplier_code: "FOUR-ORANGE", amount: S.d("86.40"),
      date: S.date("2026-09-24"), reference: "FB-2026-0918-4471"))
    page = browser.get("/ext/DOCUMENT/#{receipt.id}/entry").html
    page.should contain("<h1>Saisir l'écriture</h1>")
    page.should contain(%(src="/ext/DOCUMENT/#{receipt.id}/file/preview"))
    page.should contain(%(name="third_party" value="FOUR-ORANGE"))
    page.should contain(%(name="line-0-amount" id="pd-l0-amount" value="72,00"))
    page.should contain(%(<option value="NOR" selected>NOR ·))
    page.should contain(%(value="Orange Business · FB-2026-0918-4471"))
    page.should contain(%(hx-post="/ext/DOCUMENT/#{receipt.id}/entry/check"))
    page.should contain("L'image reste attachée à l'écriture.")
    # Numéro de la facture du fournisseur proposé : la référence du justificatif.
    page.should contain(%(name="invoice_number" value="FB-2026-0918-4471"))

    browser.get("/ext/DOCUMENT/#{receipt.id}/entry?vat_rate=").html.should contain(%(name="line-0-amount" id="pd-l0-amount" value="86,40"))

    values = {"ledger_id" => Books.ledger("A01").id.to_s, "date" => "24/09/2026", "receipt" => "", "third_party" => "FOUR-ORANGE",
              "due_date" => "", "label" => "Orange · fibre", "line-0-account" => "603", "line-0-label" => "Fibre",
              "line-0-amount" => "72", "line-0-vat_rate" => "NOR", "invoice_number" => "FB-2026-0918-4471"}
    check = browser.post("/ext/DOCUMENT/#{receipt.id}/entry/check", values, {"HX-Request" => "true"}).html
    check.should contain("86,40")
    check.should contain(%(<span class="pd-state ok">Équilibrée</span>))
    check.should_not contain("data-doc-gap")
    gap = browser.post("/ext/DOCUMENT/#{receipt.id}/entry/check", values.merge({"line-0-amount" => "70"}), {"HX-Request" => "true"}).html
    gap.should contain("Écart de 2,40")

    # Numéro vide : refusé sous son champ, rien n'est enregistré.
    missing = browser.post("/ext/DOCUMENT/#{receipt.id}/entry", values.merge({"invoice_number" => ""}))
    missing.status.should eq(422)
    missing.html.should contain(%(id="pd-doc-invoice-number-errors"))
    Api.receipt(S.admin, receipt.id).to_process?.should be_true

    response = browser.post("/ext/DOCUMENT/#{receipt.id}/entry", values)
    response.status.should eq(302)
    attached = Api.receipt(S.admin, receipt.id)
    attached.status.should eq("attached")
    entry = Acc.entry(Books.system, attached.entry_id || raise("écriture absente"))
    entry.attachment_id.should eq(receipt.original_attachment_id)
    html = browser.get("/ext/DOCUMENT/").html
    html.should contain("Écriture #{entry.receipt} enregistrée")
    Acc.received_invoice_for_entry(Books.system, entry.id).try(&.off_platform?).should be_true
    browser.get("/ext/DOCUMENT/?status=attached").html.should contain("Rattaché à #{entry.receipt}")
    # Déjà rattaché : l'écran de saisie renvoie à la consultation.
    browser.get("/ext/DOCUMENT/#{receipt.id}/entry").status.should eq(302)
  end

  it "refuse une saisie incomplète en gardant l'image et les valeurs" do
    browser = signed_in
    receipt = S.capture(S.jpeg, "ticket.jpg", Api::DetailsInput.new(supplier_name: "Station Total"))
    page = browser.get("/ext/DOCUMENT/#{receipt.id}/entry").html
    page.should contain("Fournisseur indiqué sur le justificatif : Station Total")
    response = browser.post("/ext/DOCUMENT/#{receipt.id}/entry", {"ledger_id" => Books.ledger("A01").id.to_s,
                                                                  "date" => "25/09/2026", "third_party" => "", "label" => "Carburant", "line-0-account" => "606",
                                                                  "line-0-amount" => "57,10", "line-0-vat_rate" => "NOR"})
    response.status.should eq(422)
    response.html.should contain(%(src="/ext/DOCUMENT/#{receipt.id}/file/preview"))
    response.html.should contain(%(value="Carburant"))
    Api.receipt(S.admin, receipt.id).to_process?.should be_true
  end

  it "signale une écriture d'achat déjà passée comme doublon, sans autre justificatif semblable" do
    browser = signed_in
    Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
    receipt = S.capture(S.jpeg, "copie.jpg", Api::DetailsInput.new(supplier_code: "FOUR-ORANGE", amount: S.d("86.40"),
      date: S.date("2026-09-24")))
    Acc.post_purchase(Books.system, Acc::DocumentInput.new(ledger_id: Books.ledger("A01").id, date: S.date("2026-09-24"),
      third_party: "FOUR-ORANGE", label: "Orange fibre", lines: [Acc::DocumentLineInput.new(amount: S.d("72"), account: "603",
      vat_rate: "NOR")])).value!
    page = browser.get("/ext/DOCUMENT/#{receipt.id}")
    page.status.should eq(200)
    page.html.should contain("data-doc-duplicates")
  end

  it "rattache à une écriture existante depuis la recherche" do
    browser = signed_in
    Books.card("SUPPLIER", "Orange Business", "FOUR-ORANGE")
    receipt = S.capture(S.jpeg, "copie.jpg", Api::DetailsInput.new(supplier_code: "FOUR-ORANGE", amount: S.d("86.40")))
    entry = Acc.post_purchase(Books.system, Acc::DocumentInput.new(ledger_id: Books.ledger("A01").id, date: S.date("2026-09-24"),
      third_party: "FOUR-ORANGE", label: "Orange fibre", lines: [Acc::DocumentLineInput.new(amount: S.d("72"), account: "603",
      vat_rate: "NOR")])).value!
    page = browser.get("/ext/DOCUMENT/#{receipt.id}/link").html
    page.should contain("Rattacher le justificatif")
    page.should contain(%(data-doc-candidate="entry-#{entry.id}"))
    browser.get("/ext/DOCUMENT/#{receipt.id}/link?q=introuvable").html.should contain("Aucune écriture ni facture ne correspond.")
    browser.post("/ext/DOCUMENT/#{receipt.id}/link", {"kind" => "entry", "target" => ""}).status.should eq(422)
    response = browser.post("/ext/DOCUMENT/#{receipt.id}/link", {"kind" => "entry", "target" => entry.id.to_s})
    response.status.should eq(302)
    Api.receipt(S.admin, receipt.id).entry_id.should eq(entry.id)
  end

  it "ouvre la boîte en lecture seule à un profil sans droit d'écrire, et refuse le dépôt" do
    Books.admin
    S.activate
    receipt = S.capture
    profile = PartiduoUi::Accounts.profile("Lecteur", ["document.receipt.read", "core.attachment.read"])
    PartiduoUi::Accounts.create("bob@example.com", profile: nil, profile_id: profile)
    browser = PartiduoUi::Accounts.signed_in("bob@example.com")
    html = browser.get("/ext/DOCUMENT/").html
    html.should_not contain("Photographier un justificatif")
    html.should_not contain("Saisir l'écriture")
    browser.get("/ext/DOCUMENT/#{receipt.id}/file/thumbnail").status.should eq(200)
    S.upload(browser, "/ext/DOCUMENT/capture", {} of String => String, {"file", "a.png", S::PNG}).status.should eq(403)
    browser.get("/ext/DOCUMENT/#{receipt.id}/entry").status.should eq(403)
    browser.post("/ext/DOCUMENT/#{receipt.id}/discard").status.should eq(403)
  end

  it "se traduit selon la langue de l'utilisateur" do
    browser = signed_in
    {"en" => "Take a photo of a receipt", "nl" => "Bewijsstuk fotograferen", "fr" => "Photographier un justificatif"}.each do |locale, label|
      browser.post("/language", {"locale" => locale, "next" => "/ext/DOCUMENT/"})
      browser.get("/ext/DOCUMENT/").html.should contain(label)
    end
  end
end
