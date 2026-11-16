
-- RÉSULTATS-BF
-- Structure et données initiales de la base PostgreSQL

CREATE TABLE IF NOT EXISTS public.resultats (
    matricule VARCHAR(20) PRIMARY KEY,
    nom VARCHAR(120) NOT NULL,
    serie VARCHAR(10) NOT NULL,
    moyenne NUMERIC(4,2) NOT NULL
        CHECK (moyenne BETWEEN 0 AND 20),
    admis BOOLEAN NOT NULL
);

-- Création reproductible de 50 000 candidats fictifs.
INSERT INTO public.resultats (
    matricule,
    nom,
    serie,
    moyenne,
    admis
)
SELECT
    'MAT' || LPAD(n::TEXT, 6, '0'),
    'Candidat ' || n,
    (ARRAY['A4', 'C', 'D'])[1 + (n % 3)],
    ROUND((n % 2001)::NUMERIC / 100, 2),
    ((n % 2001)::NUMERIC / 100) >= 10
FROM generate_series(1, 50000) AS n
ON CONFLICT (matricule) DO NOTHING;

-- Droits de lecture pour le serveur applicatif.
GRANT USAGE ON SCHEMA public TO resultats_app;
GRANT SELECT ON public.resultats TO resultats_app;
