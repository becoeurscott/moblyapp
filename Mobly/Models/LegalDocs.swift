import Foundation

// MARK: - Model

struct LegalSection: Identifiable {
    let id = UUID()
    var heading: String
    var body: [String] = []
    var bullets: [String] = []
}

struct LegalDoc: Identifiable {
    let id: String
    var title: String
    /// Short label shown on the hub row.
    var short: String
    var summary: String
    /// Very short label for the navigation header (avoids repeating the title).
    var nav: String
    var icon: String
    var tint: UInt32
    var intro: String
    var sections: [LegalSection]

    var version: String { LegalLibrary.version }
    var updated: String { LegalLibrary.updated }
}

struct LegalGroup: Identifiable {
    let id = UUID()
    var title: String
    var docs: [LegalDoc]
}

// MARK: - Company identity
//
// ⚠️ À COMPLÉTER avant publication sur l'App Store : ces valeurs apparaissent
// telles quelles dans les Mentions légales et les CGU. Remplacer chaque
// « [à compléter] » par les données réelles de la société.

enum LegalCompany {
    static let name = "MOBLY SARL"
    static let legalForm = "Société à responsabilité limitée (SARL)"
    static let capital = "[à compléter] FCFA"
    static let rccm = "[à compléter]"
    static let niu = "[à compléter]"
    static let address = "[à compléter], Douala, Cameroun"
    static let director = "[à compléter]"
    static let email = "legal@mobly.cm"
    static let support = "support@mobly.cm"
    static let privacy = "confidentialite@mobly.cm"
    static let abuse = "signalement@mobly.cm"
    static let phone = "[à compléter]"
    static let host = "[à compléter] (hébergeur de l'application et de la base de données)"
    static let website = "mobly.cm"
}

// MARK: - Library

enum LegalLibrary {
    static let version = "1.0"
    static let updated = "25 juillet 2026"

    static var groups: [LegalGroup] {
        [
            LegalGroup(title: "Le contrat", docs: [cgu, servicesPayants]),
            LegalGroup(title: "Vos données", docs: [confidentialite, cookies]),
            LegalGroup(title: "La communauté", docs: [charte, reglesAnnonces, moderation, securiteVisites, proprieteIntellectuelle]),
            LegalGroup(title: "L'entreprise", docs: [mentionsLegales]),
        ]
    }

    static var all: [LegalDoc] { groups.flatMap(\.docs) }

    static func doc(_ id: String) -> LegalDoc? { all.first { $0.id == id } }

    // MARK: 1 — CGU

    static let cgu = LegalDoc(
        id: "cgu",
        title: "Conditions Générales d'Utilisation",
        short: "Conditions Générales d'Utilisation",
        summary: "Le contrat qui vous lie à Mobly",
        nav: "CGU",
        icon: "doc.text.fill",
        tint: 0xEEF0FE,
        intro: "Les présentes Conditions Générales d'Utilisation (« CGU ») encadrent l'accès et l'utilisation de l'application Mobly. En créant un compte ou en utilisant Mobly, vous les acceptez sans réserve. Si vous ne les acceptez pas, vous devez cesser d'utiliser l'application.",
        sections: [
            LegalSection(
                heading: "1. Objet et définitions",
                body: ["Mobly est une plateforme de mise en relation entre des personnes cherchant un espace à louer (« Visiteurs ») et des personnes proposant un espace (« Propriétaires »). Mobly édite l'application, héberge les annonces et fournit les outils de communication."],
                bullets: [
                    "« Annonce » : la publication décrivant un espace proposé par un Propriétaire.",
                    "« Contenu » : tout texte, photo, message ou note vocale publié par un utilisateur.",
                    "« Services » : l'ensemble des fonctionnalités de l'application, gratuites ou payantes."
                ]
            ),
            LegalSection(
                heading: "2. Mobly est un intermédiaire technique, pas une agence immobilière",
                body: [
                    "Mobly n'est ni propriétaire, ni locataire, ni bailleur, ni agent immobilier, ni courtier, ni garant. Mobly n'est pas partie au contrat de location conclu entre un Visiteur et un Propriétaire.",
                    "Mobly ne détient, ne visite, ne vérifie et n'expertise aucun bien. Les Annonces sont rédigées et publiées sous la seule responsabilité des Propriétaires."
                ],
                bullets: [
                    "Le contrat de bail, son contenu, son exécution et sa résiliation ne concernent que le Visiteur et le Propriétaire.",
                    "Mobly n'encaisse ni loyer, ni caution, ni avance, ni frais de visite pour le compte d'un Propriétaire.",
                    "Aucune information affichée dans une Annonce ne constitue une garantie de Mobly."
                ]
            ),
            LegalSection(
                heading: "3. Accès au service et compte",
                body: ["L'inscription requiert un numéro de téléphone valide vérifié par code SMS. Vous devez avoir la capacité juridique de contracter et fournir des informations exactes."],
                bullets: [
                    "Vous êtes seul responsable de la confidentialité de votre compte et de toute activité menée depuis celui-ci.",
                    "Un compte est personnel : sa cession, sa location ou son partage sont interdits.",
                    "Vous devez nous signaler sans délai toute utilisation non autorisée de votre compte."
                ]
            ),
            LegalSection(
                heading: "4. Engagements de l'utilisateur",
                body: ["En utilisant Mobly, vous vous engagez à respecter la loi camerounaise et les présentes CGU."],
                bullets: [
                    "Ne publier que des Annonces sincères, portant sur un bien réel dont vous avez le droit de disposer.",
                    "Ne pas usurper l'identité d'un tiers ni créer de faux comptes.",
                    "Ne pas solliciter ou effectuer de paiement en dehors des canaux prévus, ni demander d'argent avant une visite.",
                    "Ne pas collecter, extraire ou réutiliser les données des autres utilisateurs.",
                    "Ne pas contourner, sonder ou perturber le fonctionnement technique de l'application."
                ]
            ),
            LegalSection(
                heading: "5. Contenu publié par les utilisateurs",
                body: [
                    "Vous restez titulaire des droits sur le Contenu que vous publiez. Vous concédez à Mobly une licence non exclusive, gratuite et mondiale d'héberger, reproduire, redimensionner et afficher ce Contenu aux seules fins d'exploiter et de promouvoir les Services, pour la durée de publication de l'Annonce et la durée de conservation légale qui suit.",
                    "Vous garantissez détenir tous les droits sur le Contenu publié et garantissez Mobly contre toute réclamation d'un tiers à ce sujet."
                ]
            ),
            LegalSection(
                heading: "6. Modération et suspension",
                body: ["Mobly peut, sans préavis et sans indemnité, refuser, modifier le classement, dépublier ou supprimer toute Annonce, et suspendre ou fermer tout compte en cas de manquement aux CGU, de signalement fondé, de soupçon de fraude ou d'exigence légale."],
                bullets: [
                    "Les mesures sont proportionnées : avertissement, retrait du Contenu, suspension temporaire, fermeture définitive.",
                    "En cas de fermeture, les sommes déjà versées pour un service payant en cours ne sont pas remboursées si la fermeture résulte d'un manquement de votre part."
                ]
            ),
            LegalSection(
                heading: "7. Disponibilité du service",
                body: ["Mobly est fourni « en l'état » et « selon disponibilité ». Mobly ne garantit pas une disponibilité continue et sans erreur, et peut interrompre les Services pour maintenance, mise à jour ou raison de sécurité."]
            ),
            LegalSection(
                heading: "8. Limitation de responsabilité",
                body: ["Dans la limite permise par la loi applicable, Mobly n'est pas responsable :"],
                bullets: [
                    "de l'inexactitude, de l'illégalité ou de la fausseté d'une Annonce ou d'un Contenu publié par un utilisateur ;",
                    "de la conclusion, de l'exécution ou de l'inexécution d'un contrat de location entre utilisateurs ;",
                    "des sommes remises directement entre utilisateurs, notamment une caution, une avance ou des frais de visite ;",
                    "du comportement d'un utilisateur, en ligne comme hors ligne, y compris lors d'une visite ;",
                    "des dommages indirects, tels que perte d'exploitation, perte de chance, perte de données ou préjudice d'image.",
                    "En tout état de cause, si la responsabilité de Mobly était retenue, elle serait limitée aux sommes que vous avez effectivement versées à Mobly au cours des douze (12) mois précédant le fait générateur."
                ]
            ),
            LegalSection(
                heading: "9. Garantie d'éviction",
                body: ["Vous garantissez Mobly contre toute réclamation, action ou condamnation résultant de votre Contenu, de votre utilisation des Services ou de votre manquement aux présentes CGU, y compris les frais de défense raisonnables."]
            ),
            LegalSection(
                heading: "10. Durée, résiliation et suppression du compte",
                body: ["Les CGU s'appliquent tant que vous utilisez Mobly. Vous pouvez supprimer votre compte à tout moment depuis Profil › Confidentialité et sécurité. Certaines données sont conservées après la suppression lorsque la loi l'impose (voir la Politique de confidentialité)."]
            ),
            LegalSection(
                heading: "11. Modification des CGU",
                body: ["Mobly peut modifier les CGU pour tenir compte d'évolutions légales ou fonctionnelles. La version applicable est celle affichée dans l'application. En cas de modification substantielle, vous en êtes informé et l'usage continu des Services vaut acceptation."]
            ),
            LegalSection(
                heading: "12. Droit applicable et litiges",
                body: ["Les présentes CGU sont soumises au droit camerounais. En cas de litige, les parties rechercheront d'abord une solution amiable en écrivant à \(LegalCompany.email). À défaut d'accord dans un délai de trente (30) jours, le litige sera porté devant les juridictions compétentes de Douala."]
            ),
        ]
    )

    // MARK: 2 — Services payants

    static let servicesPayants = LegalDoc(
        id: "services",
        title: "Conditions des services payants",
        short: "Services payants et boost",
        summary: "Boost, paiement Mobile Money, remboursement",
        nav: "Services payants",
        icon: "creditcard.fill",
        tint: 0xFFF1EA,
        intro: "La publication d'une annonce sur Mobly est gratuite. Certaines fonctionnalités de visibilité sont payantes. Ces conditions complètent les CGU et s'appliquent à tout achat effectué dans l'application.",
        sections: [
            LegalSection(
                heading: "1. Services concernés",
                body: ["Le « Boost » est un service de mise en avant qui remonte une annonce dans les résultats de recherche pendant une durée déterminée. Les formules et tarifs affichés dans l'application au moment de l'achat font foi."],
                bullets: [
                    "3 jours — 500 FCFA",
                    "7 jours — 1 000 FCFA",
                    "30 jours — 3 000 FCFA",
                    "Les prix sont exprimés en francs CFA, toutes taxes comprises le cas échéant."
                ]
            ),
            LegalSection(
                heading: "2. Ce que le boost garantit — et ne garantit pas",
                body: ["Le Boost garantit un emplacement privilégié dans les résultats pendant la durée achetée. Il ne garantit ni un nombre de vues, ni un nombre de contacts, ni la location effective de l'espace."]
            ),
            LegalSection(
                heading: "3. Paiement",
                body: ["Les paiements sont opérés par des prestataires de paiement mobile (Mobile Money, Orange Money) ou tout autre moyen proposé dans l'application. Mobly ne stocke aucune donnée de paiement complète."],
                bullets: [
                    "Le service est activé après confirmation du paiement par le prestataire.",
                    "Les frais éventuels prélevés par l'opérateur restent à votre charge.",
                    "En cas d'échec ou de double débit, écrivez à \(LegalCompany.support) avec la référence de la transaction."
                ]
            ),
            LegalSection(
                heading: "4. Absence de rétractation et remboursement",
                body: ["Le service étant exécuté immédiatement et intégralement dès son activation, il n'ouvre pas droit à rétractation une fois lancé."],
                bullets: [
                    "Un remboursement au prorata est possible si le service n'a pas pu être rendu du fait d'un dysfonctionnement imputable à Mobly.",
                    "Aucun remboursement n'est dû si l'annonce est retirée, rendue indisponible ou supprimée à votre initiative, ni si elle est sanctionnée pour manquement aux règles de publication."
                ]
            ),
            LegalSection(
                heading: "5. Facturation",
                body: ["Un justificatif est disponible dans l'application après chaque achat. Toute contestation doit être adressée dans un délai de trente (30) jours à \(LegalCompany.support)."]
            ),
            LegalSection(
                heading: "6. Évolution des offres",
                body: ["Mobly peut faire évoluer ses formules et ses tarifs. Les modifications n'affectent pas les services déjà payés et en cours d'exécution."]
            ),
        ]
    )

    // MARK: 3 — Confidentialité

    static let confidentialite = LegalDoc(
        id: "confidentialite",
        title: "Politique de confidentialité",
        short: "Politique de confidentialité",
        summary: "Quelles données, pourquoi, combien de temps",
        nav: "Confidentialité",
        icon: "lock.shield.fill",
        tint: 0xEAF6EF,
        intro: "Cette politique explique quelles données personnelles Mobly collecte, pourquoi, avec qui elles sont partagées et quels sont vos droits. Elle s'applique à l'application Mobly et au site \(LegalCompany.website).",
        sections: [
            LegalSection(
                heading: "1. Responsable de traitement",
                body: ["\(LegalCompany.name), \(LegalCompany.address), est responsable du traitement des données décrites ci-dessous. Contact : \(LegalCompany.privacy)."]
            ),
            LegalSection(
                heading: "2. Données collectées",
                bullets: [
                    "Identité et contact : nom, numéro de téléphone, adresse e-mail, photo de profil.",
                    "Compte : rôle (visiteur ou propriétaire), statut de vérification, langue, préférences.",
                    "Annonces : titre, description, adresse ou quartier, prix, photos, équipements.",
                    "Communications : messages, notes vocales, journaux d'appels internes (date, durée — jamais le contenu audio d'un appel).",
                    "Usage : pages consultées, annonces vues, favoris, recherches enregistrées.",
                    "Technique : modèle d'appareil, version du système, identifiant d'installation, adresse IP, journaux d'erreurs.",
                    "Localisation approximative, uniquement si vous l'autorisez, pour afficher les espaces proches."
                ]
            ),
            LegalSection(
                heading: "3. Finalités et bases légales",
                bullets: [
                    "Fournir le service et exécuter le contrat : compte, publication, recherche, messagerie, appels.",
                    "Sécurité et prévention de la fraude, sur la base de notre intérêt légitime.",
                    "Amélioration du produit et statistiques agrégées, sur la base de notre intérêt légitime.",
                    "Notifications et informations sur le service ; communications promotionnelles uniquement avec votre consentement.",
                    "Respect de nos obligations légales et réponse aux réquisitions des autorités compétentes."
                ]
            ),
            LegalSection(
                heading: "4. Numéro de téléphone masqué",
                body: ["Les appels et messages passent par Mobly. Votre numéro personnel n'est pas affiché à votre interlocuteur tant que vous ne le communiquez pas vous-même. Nous conservons les métadonnées de ces échanges pour la sécurité et la résolution des litiges."]
            ),
            LegalSection(
                heading: "5. Destinataires",
                body: ["Vos données ne sont ni vendues, ni louées. Elles sont accessibles :"],
                bullets: [
                    "aux équipes internes habilitées de Mobly ;",
                    "aux prestataires techniques agissant sur instruction (hébergement, envoi de SMS, paiement mobile, outils de mesure d'audience) ;",
                    "aux autres utilisateurs, pour les seules informations que vous rendez publiques (nom, photo, annonces, avis) ;",
                    "aux autorités judiciaires ou administratives, sur réquisition régulière."
                ]
            ),
            LegalSection(
                heading: "6. Transferts hors du Cameroun",
                body: ["Certains prestataires peuvent héberger ou traiter des données hors du Cameroun. Nous exigeons dans ce cas des garanties contractuelles appropriées de confidentialité et de sécurité."]
            ),
            LegalSection(
                heading: "7. Durées de conservation",
                bullets: [
                    "Compte actif : pendant toute la durée d'utilisation.",
                    "Après suppression du compte : trente (30) jours pour permettre une restauration, puis suppression ou anonymisation.",
                    "Messages et métadonnées d'échanges : jusqu'à trois (3) ans, pour la preuve et la gestion des litiges.",
                    "Données de facturation : dix (10) ans, conformément aux obligations comptables.",
                    "Journaux de connexion : conservés conformément à la réglementation camerounaise applicable."
                ]
            ),
            LegalSection(
                heading: "8. Vos droits",
                body: ["Vous disposez d'un droit d'accès, de rectification, d'effacement, d'opposition, de limitation et de portabilité, ainsi que du droit de définir des directives sur le sort de vos données après votre décès."],
                bullets: [
                    "Exercice des droits : \(LegalCompany.privacy), en justifiant de votre identité.",
                    "Réponse dans un délai maximum de trente (30) jours.",
                    "Vous pouvez saisir l'autorité compétente si la réponse ne vous satisfait pas."
                ]
            ),
            LegalSection(
                heading: "9. Sécurité",
                body: ["Nous mettons en œuvre des mesures raisonnables : chiffrement des échanges, accès restreint aux données, journalisation des accès, sauvegardes. Aucun système n'étant infaillible, nous vous informerons en cas de violation de données susceptible d'engendrer un risque élevé pour vos droits."]
            ),
            LegalSection(
                heading: "10. Mineurs",
                body: ["Mobly n'est pas destiné aux personnes de moins de 18 ans. Un compte identifié comme appartenant à un mineur est supprimé."]
            ),
        ]
    )

    // MARK: 4 — Cookies

    static let cookies = LegalDoc(
        id: "cookies",
        title: "Politique relative aux cookies et traceurs",
        short: "Cookies et traceurs",
        summary: "Mesure d'audience et identifiants techniques",
        nav: "Cookies",
        icon: "circle.grid.cross.fill",
        tint: 0xF3EEFB,
        intro: "L'application mobile Mobly n'utilise pas de cookies au sens du navigateur, mais des technologies équivalentes : stockage local, identifiants d'installation et outils de mesure d'audience. Le site \(LegalCompany.website) utilise des cookies.",
        sections: [
            LegalSection(
                heading: "1. Traceurs strictement nécessaires",
                body: ["Ils permettent de vous maintenir connecté, de mémoriser votre langue et vos préférences d'affichage, et de sécuriser vos sessions. Ils ne peuvent pas être désactivés sans rendre le service inutilisable."]
            ),
            LegalSection(
                heading: "2. Mesure d'audience",
                body: ["Nous mesurons l'usage de l'application (écrans consultés, pannes) pour l'améliorer. Ces données sont agrégées et ne servent pas à vous cibler publicitairement."]
            ),
            LegalSection(
                heading: "3. Traceurs publicitaires",
                body: ["Mobly n'utilise pas de traceurs publicitaires tiers à la date de mise à jour de ce document. Si cela devait changer, votre consentement préalable serait recueilli."]
            ),
            LegalSection(
                heading: "4. Vos choix",
                bullets: [
                    "Réglages de l'appareil : vous pouvez limiter le suivi publicitaire et réinitialiser l'identifiant d'installation.",
                    "Notifications : activables et désactivables depuis Profil › Notifications.",
                    "Localisation : révocable à tout moment dans les réglages iOS."
                ]
            ),
        ]
    )

    // MARK: 5 — Charte communauté

    static let charte = LegalDoc(
        id: "charte",
        title: "Charte de la communauté",
        short: "Charte de la communauté",
        summary: "Les règles de comportement sur Mobly",
        nav: "Charte",
        icon: "person.2.fill",
        tint: 0xEEF0FE,
        intro: "Mobly ne fonctionne que si la confiance circule dans les deux sens. Cette charte s'applique à tous : visiteurs, propriétaires et agences. Son non-respect peut entraîner la suspension du compte.",
        sections: [
            LegalSection(
                heading: "1. Respect",
                bullets: [
                    "Pas d'insulte, de menace, de harcèlement ni de propos discriminatoires.",
                    "Pas de sollicitation à caractère sexuel ni de contenu à caractère intime.",
                    "Répondez avec courtoisie, même pour dire non."
                ]
            ),
            LegalSection(
                heading: "2. Honnêteté",
                bullets: [
                    "Photos réelles et récentes de l'espace proposé, jamais des images trouvées en ligne.",
                    "Prix affiché = prix demandé. Aucun frais caché révélé après le premier contact.",
                    "Retirez ou marquez indisponible une annonce dont l'espace est déjà loué."
                ]
            ),
            LegalSection(
                heading: "3. Sécurité des échanges",
                bullets: [
                    "Gardez la conversation dans Mobly : c'est votre seule preuve en cas de litige.",
                    "Ne communiquez jamais un code reçu par SMS, un mot de passe ou vos identifiants Mobile Money.",
                    "Méfiez-vous de toute urgence artificielle : « payez maintenant ou je loue à quelqu'un d'autre » est le principal signal d'arnaque."
                ]
            ),
            LegalSection(
                heading: "4. Non-discrimination",
                body: ["Refuser un locataire en raison de son origine, de son ethnie, de sa religion, de son sexe, de sa situation de handicap, de son état de santé ou de sa situation familiale est interdit sur Mobly et sanctionné."]
            ),
            LegalSection(
                heading: "5. Sanctions",
                body: ["Selon la gravité : avertissement, retrait de l'annonce, perte du badge vérifié, suspension temporaire, ou fermeture définitive du compte sans remboursement des services payants en cours."]
            ),
        ]
    )

    // MARK: 6 — Règles annonces

    static let reglesAnnonces = LegalDoc(
        id: "annonces",
        title: "Règles de publication des annonces",
        short: "Règles de publication",
        summary: "Ce qui est autorisé, ce qui est interdit",
        nav: "Règles d'annonce",
        icon: "checkmark.seal.fill",
        tint: 0xEAF6EF,
        intro: "Toute annonce publiée sur Mobly doit respecter ces règles. Elles s'ajoutent aux CGU et permettent à Mobly de retirer un contenu non conforme sans préavis.",
        sections: [
            LegalSection(
                heading: "1. Le bien",
                bullets: [
                    "L'espace doit exister, être identifiable et être réellement disponible à la location.",
                    "Vous devez être propriétaire du bien ou disposer d'un mandat écrit du propriétaire.",
                    "Une annonce = un espace. Les annonces en double sont fusionnées ou supprimées."
                ]
            ),
            LegalSection(
                heading: "2. Les informations",
                bullets: [
                    "Localisation exacte au moins au niveau du quartier.",
                    "Prix réel, dans la devise et l'unité indiquées (par jour ou par mois).",
                    "Description sincère de l'état, des équipements et des charges éventuelles.",
                    "Aucune coordonnée personnelle (numéro, e-mail, lien externe) dans le titre, la description ou les photos."
                ]
            ),
            LegalSection(
                heading: "3. Les photos",
                bullets: [
                    "Photos prises par vous ou dont vous détenez les droits.",
                    "Pas de filigrane d'un autre site, pas de photo d'un autre bien, pas de rendu 3D présenté comme une photo.",
                    "Aucun visage ni plaque d'immatriculation identifiable sans autorisation."
                ]
            ),
            LegalSection(
                heading: "4. Contenus interdits",
                bullets: [
                    "Biens illégaux, occupations sans titre, sous-location non autorisée.",
                    "Offres d'emploi, ventes de véhicules, services financiers, ou tout objet sans lien avec un espace à louer.",
                    "Demandes de paiement anticipé, de « frais de dossier » avant visite ou de transfert vers un tiers.",
                    "Contenus à caractère politique, haineux, violent, sexuel ou trompeur."
                ]
            ),
            LegalSection(
                heading: "5. Conséquences",
                body: ["Une annonce non conforme peut être dépubliée, déclassée ou supprimée. Les manquements répétés entraînent la fermeture du compte. Aucun remboursement n'est dû pour un boost actif sur une annonce sanctionnée."]
            ),
        ]
    )

    // MARK: 7 — Modération / signalement

    static let moderation = LegalDoc(
        id: "moderation",
        title: "Politique de modération et de signalement",
        short: "Modération et signalement",
        summary: "Comment nous traitons les signalements",
        nav: "Signalement",
        icon: "flag.fill",
        tint: 0xFFF1EA,
        intro: "Mobly héberge des contenus publiés par ses utilisateurs. Nous n'exerçons pas de contrôle a priori sur chaque annonce, mais nous agissons promptement dès qu'un contenu illicite ou non conforme nous est signalé.",
        sections: [
            LegalSection(
                heading: "1. Signaler un contenu ou un utilisateur",
                body: ["Utilisez le bouton de signalement présent sur une annonce, une conversation ou un profil, ou écrivez à \(LegalCompany.abuse)."],
                bullets: [
                    "Indiquez le lien ou l'identifiant de l'annonce, la date, et le motif.",
                    "Joignez si possible une capture d'écran.",
                    "Un signalement manifestement abusif ou de mauvaise foi peut lui-même être sanctionné."
                ]
            ),
            LegalSection(
                heading: "2. Traitement",
                bullets: [
                    "Accusé de réception sous 48 heures ouvrées.",
                    "Examen sous 7 jours ouvrés ; immédiat en cas de risque grave pour les personnes.",
                    "Mesure proportionnée : demande de correction, retrait, déclassement, suspension ou fermeture.",
                    "L'auteur du contenu est informé de la mesure et de son motif, sauf si la loi l'interdit."
                ]
            ),
            LegalSection(
                heading: "3. Contestation",
                body: ["Toute décision de modération peut être contestée dans les trente (30) jours en écrivant à \(LegalCompany.email). La demande est réexaminée par une personne différente de celle ayant pris la décision initiale."]
            ),
            LegalSection(
                heading: "4. Coopération avec les autorités",
                body: ["Mobly conserve les éléments nécessaires à l'identification des auteurs de contenus et les communique aux autorités judiciaires sur réquisition régulière, conformément à la réglementation camerounaise sur la cybersécurité et la cybercriminalité."]
            ),
        ]
    )

    // MARK: 8 — Sécurité des visites

    static let securiteVisites = LegalDoc(
        id: "visites",
        title: "Sécurité des visites et prévention des arnaques",
        short: "Sécurité des visites",
        summary: "Ne payez jamais avant d'avoir visité",
        nav: "Sécurité des visites",
        icon: "exclamationmark.shield.fill",
        tint: 0xFFF1EA,
        intro: "Une visite se déroule hors de l'application, entre deux personnes majeures et responsables. Mobly n'accompagne pas les visites et ne peut pas en garantir le déroulement. Ces règles réduisent fortement le risque.",
        sections: [
            LegalSection(
                heading: "1. Avant la visite",
                bullets: [
                    "Échangez uniquement dans Mobly : la conversation constitue votre trace.",
                    "Vérifiez la cohérence entre les photos, le prix et l'adresse annoncés.",
                    "Prévenez un proche du lieu et de l'heure du rendez-vous.",
                    "Privilégiez une visite de jour."
                ]
            ),
            LegalSection(
                heading: "2. Pendant la visite",
                bullets: [
                    "Ne remettez aucune somme avant d'avoir vu l'espace et vérifié le titre du bailleur.",
                    "Exigez un reçu écrit pour toute somme versée, même une avance.",
                    "N'entrez pas dans un lieu qui ne correspond pas à l'annonce."
                ]
            ),
            LegalSection(
                heading: "3. Signaux d'alerte",
                bullets: [
                    "Un prix nettement inférieur au marché.",
                    "Un interlocuteur qui refuse la visite et demande un virement pour « réserver ».",
                    "Une demande de paiement vers un compte Mobile Money personnel présenté comme celui de Mobly.",
                    "Une pression au paiement immédiat ou un changement soudain d'interlocuteur."
                ]
            ),
            LegalSection(
                heading: "4. Rôle de Mobly",
                body: ["Mobly n'organise pas les visites, n'est pas présent lors des rendez-vous, ne collecte aucune caution et n'intervient pas dans les paiements réalisés directement entre utilisateurs. En cas d'infraction, déposez plainte auprès des autorités compétentes et signalez-nous le compte concerné à \(LegalCompany.abuse) : nous coopérerons avec les autorités."]
            ),
        ]
    )

    // MARK: 9 — Propriété intellectuelle

    static let proprieteIntellectuelle = LegalDoc(
        id: "pi",
        title: "Propriété intellectuelle et signalement d'atteinte",
        short: "Propriété intellectuelle",
        summary: "Marque, photos, contenus protégés",
        nav: "Propriété intellectuelle",
        icon: "c.circle.fill",
        tint: 0xF3EEFB,
        intro: "Cette politique protège les droits de Mobly comme ceux de ses utilisateurs et des tiers.",
        sections: [
            LegalSection(
                heading: "1. Droits de Mobly",
                body: ["La marque « Mobly », le logo, l'interface, les textes, l'architecture, les bases de données et le code de l'application sont la propriété exclusive de \(LegalCompany.name) ou de ses concédants."],
                bullets: [
                    "Toute reproduction, extraction, réutilisation ou adaptation, totale ou partielle, sans autorisation écrite est interdite.",
                    "L'extraction automatisée des annonces et des données de la plateforme est interdite et constitue une atteinte au droit du producteur de base de données."
                ]
            ),
            LegalSection(
                heading: "2. Droits des utilisateurs",
                body: ["Vous conservez vos droits sur vos photos et vos textes. Vous accordez à Mobly la licence d'usage décrite à l'article 5 des CGU, strictement limitée à l'exploitation du service."]
            ),
            LegalSection(
                heading: "3. Signaler une atteinte",
                body: ["Si un contenu publié sur Mobly porte atteinte à vos droits, écrivez à \(LegalCompany.email) en précisant :"],
                bullets: [
                    "votre identité et votre qualité pour agir ;",
                    "le contenu concerné et sa localisation précise dans l'application ;",
                    "la justification de vos droits ;",
                    "une déclaration de bonne foi.",
                    "Nous retirons ou rendons inaccessible tout contenu manifestement contrefaisant après examen."
                ]
            ),
        ]
    )

    // MARK: 10 — Mentions légales

    static let mentionsLegales = LegalDoc(
        id: "mentions",
        title: "Mentions légales",
        short: "Mentions légales",
        summary: "Éditeur, hébergeur, contact",
        nav: "Mentions légales",
        icon: "building.columns.fill",
        tint: 0xEEF0FE,
        intro: "Informations relatives à l'éditeur de l'application Mobly et du site \(LegalCompany.website).",
        sections: [
            LegalSection(
                heading: "1. Éditeur",
                bullets: [
                    "Dénomination : \(LegalCompany.name)",
                    "Forme juridique : \(LegalCompany.legalForm)",
                    "Capital social : \(LegalCompany.capital)",
                    "Siège social : \(LegalCompany.address)",
                    "RCCM : \(LegalCompany.rccm)",
                    "Numéro d'identifiant unique (NIU) : \(LegalCompany.niu)",
                    "Directeur de la publication : \(LegalCompany.director)",
                    "Téléphone : \(LegalCompany.phone)",
                    "E-mail : \(LegalCompany.email)"
                ]
            ),
            LegalSection(
                heading: "2. Hébergement",
                bullets: ["Hébergeur : \(LegalCompany.host)"]
            ),
            LegalSection(
                heading: "3. Contacts utiles",
                bullets: [
                    "Support utilisateurs : \(LegalCompany.support)",
                    "Données personnelles : \(LegalCompany.privacy)",
                    "Signalement d'abus : \(LegalCompany.abuse)",
                    "Questions juridiques : \(LegalCompany.email)"
                ]
            ),
            LegalSection(
                heading: "4. Version des documents",
                body: ["Version \(version), en vigueur depuis le \(updated). Les versions antérieures sont disponibles sur demande à \(LegalCompany.email)."]
            ),
        ]
    )
}
