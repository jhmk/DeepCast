import Foundation

/// Default trust tiers by domain (spec 5.1). Unknown domains are C. Editable lists come later.
enum SourceTrust {
    static let tierA: [String] = [
        "nature.com", "science.org", "sciencemag.org", "cell.com", "thelancet.com", "nejm.org", "bmj.com",
        "pnas.org", "plos.org", "springer.com", "link.springer.com", "wiley.com", "sciencedirect.com",
        "ncbi.nlm.nih.gov", "pubmed.ncbi.nlm.nih.gov", "europepmc.org", "doi.org", "jstor.org",
        "who.int", "un.org", "oecd.org", "worldbank.org", "europa.eu", "destatis.de", "rki.de",
        "bundesamt.de", "umweltbundesamt.de", "nasa.gov", "esa.int", "noaa.gov", "cdc.gov", "nih.gov",
        "mpg.de", "helmholtz.de", "fraunhofer.de", "leibniz-gemeinschaft.de", "awmf.org", "cochrane.org",
        "cochranelibrary.com", "ipcc.ch", "auswaertiges-amt.de",
    ]

    static let tierB: [String] = [
        "wikipedia.org", "britannica.com", "tagesschau.de", "zdf.de", "ard.de", "br.de", "ndr.de",
        "wdr.de", "swr.de", "mdr.de", "hr.de", "rbb24.de", "deutschlandfunk.de", "deutschlandfunkkultur.de",
        "dlf.de", "quarks.de", "planet-wissen.de", "zeit.de", "spiegel.de", "sueddeutsche.de", "faz.net",
        "nzz.ch", "srf.ch", "orf.at", "taz.de", "handelsblatt.com", "tagesspiegel.de", "spektrum.de",
        "scinexx.de", "wissenschaft.de", "heise.de", "golem.de", "geo.de", "nationalgeographic.com",
        "nationalgeographic.de", "bbc.com", "bbc.co.uk", "theguardian.com", "nytimes.com",
        "washingtonpost.com", "reuters.com", "apnews.com", "dpa.com", "economist.com",
        "scientificamerican.com", "newscientist.com", "quantamagazine.org", "arstechnica.com",
        "arxiv.org", "biorxiv.org", "medrxiv.org", "bpb.de", "mdr.de", "dw.com", "smithsonianmag.com",
        "livescience.com", "phys.org", "sciencedaily.com", "statista.com", "ourworldindata.org",
        // Travel: editorial guide books and magazines
        "wikivoyage.org", "lonelyplanet.com", "lonelyplanet.de", "merian.de", "marcopolo.de", "dumontreise.de",
        "baedeker.com", "fodors.com", "frommers.com", "roughguides.com", "ricksteves.com", "adac.de",
        "nationalgeographic.co.uk", "travelandleisure.com", "cntraveler.com",
    ]

    static let tierD: [String] = [
        "reddit.com", "facebook.com", "x.com", "twitter.com", "tiktok.com", "instagram.com", "quora.com",
        "gutefrage.net", "pinterest.com", "youtube.com", "medium.com", "linkedin.com", "telegram.org",
    ]

    /// Official tourism boards: usually correct facts, but advertising (tier C + note).
    static func isTourismBoard(host: String) -> Bool {
        let host = host.lowercased()
        let labels = host.split(separator: ".").map(String.init)
        if labels.contains(where: { $0.hasPrefix("visit") || $0.hasPrefix("discover") && $0.count > 8 }) { return true }
        if host.hasSuffix(".travel") { return true }
        return ["tourism", "tourismus", "turismo", "tourisme", "toerisme", "turism"].contains { host.contains($0) }
    }

    /// Preprint servers are tier B but flagged.
    static let preprints: [String] = ["arxiv.org", "biorxiv.org", "medrxiv.org", "ssrn.com", "preprints.org"]

    static func tier(forHost host: String) -> TrustTier {
        let host = host.lowercased()
        if isTourismBoard(host: host), !matches(host, tierA) { return .c }
        if matches(host, tierA) || host.hasSuffix(".gov") || host.hasSuffix(".bund.de") { return .a }
        if matches(host, tierD) { return .d }
        if matches(host, tierB) || host.hasSuffix(".edu") || host.hasSuffix(".ac.uk")
            || host.hasPrefix("uni-") || host.contains(".uni-") || host.contains("tu-") { return .b }
        return .c
    }

    static func isPreprint(host: String) -> Bool { matches(host.lowercased(), preprints) }

    /// "www.spektrum.de" → "spektrum.de", "de.wikipedia.org" → "wikipedia.org" (two labels;
    /// good enough for de/com/org; co.uk handled explicitly).
    static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".")
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if ["co.uk", "ac.uk", "com.au", "co.jp"].contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    private static func matches(_ host: String, _ list: [String]) -> Bool {
        list.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
