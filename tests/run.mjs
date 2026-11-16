// Tests de l'analyse (sans navigateur) : node tests/run.mjs
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const html = fs.readFileSync(root + 'index.html', 'utf8');
const ctx = { URL };
ctx.globalThis = ctx;
vm.createContext(ctx);
for (const id of ['parser-js', 'layout-js', 'web-js']) {
  const m = html.match(new RegExp('<script id="' + id + '">([\\s\\S]*?)</script>'));
  assert.ok(m, 'bloc ' + id + ' introuvable');
  vm.runInContext(m[1], ctx, { filename: id });
}
const { RP, LAYOUT, WEB } = ctx;
const plain = x => JSON.parse(JSON.stringify(x));
let n = 0;
const test = (name, fn) => { fn(); n++; console.log('ok  ' + name); };

test('version : page, fichier VERSION et journal concordent', () => {
  const v = html.match(/<meta name="transposeur-version" content="([^"]+)">/)[1];
  assert.match(v, /^\d{4}\.\d{2}\.\d{2}-\d+$/);
  assert.equal(fs.readFileSync(root + 'VERSION', 'utf8').trim(), v);
  assert.ok(fs.readFileSync(root + 'CHANGELOG.md', 'utf8').includes('## ' + v), 'version absente de CHANGELOG.md');
  assert.ok(html.trimEnd().endsWith('</html>'));
});

test('bibliothèques : libs.txt correspond aux versions attendues par la page', () => {
  const libs = fs.readFileSync(root + 'libs.txt', 'utf8');
  const want = JSON.parse(libs.match(/^@ (.+)$/m)[1]);
  const got = html.match(/const LIBV=\{pdfjs:'([^']+)',tesseract:'([^']+)'\}/);
  assert.deepEqual(want, { pdfjs: got[1], tesseract: got[2] });
  const files = libs.split('\n').filter(l => l && !/^[#@]/.test(l)).map(l => l.split(' '));
  for (const [name, url, sha] of files) {
    assert.match(url, /^https:\/\/cdn\.jsdelivr\.net\/npm\//, name);
    assert.match(sha, /^[0-9a-f]{64}$/, name);
  }
  for (const f of ['pdf.min.mjs', 'pdf.worker.min.mjs', 'tesseract.min.js', 'worker.min.js', 'fra.traineddata.gz', 'eng.traineddata.gz'])
    assert.ok(files.some(x => x[0] === f), f + ' manque dans libs.txt');
  assert.ok(html.includes('pdfjs-dist@' + want.pdfjs + '/') && html.includes('tesseract.js@' + want.tesseract + '/'));
});

const RECETTE = `POULET AU BEURRE
Un classique réconfortant, prêt en moins d'une heure.

Portions : 4
Préparation : 15 min
Cuisson : 40 min

Ingrédients
800 g de hauts de cuisse de poulet désossés
125 ml (2 tasse) de yogourt nature
2 gousses d'ail hachées
15 ml (1 c. à soupe) de garam masala
1 boîte de 796 ml de tomates broyées
Sel et poivre

Préparation
1. Dans un bol, mélanger le poulet, le yogourt, l'ail et le garam masala. Laisser mariner 30 minutes au réfrigérateur.
2. Dans une grande casserole, dorer le poulet dans le beurre à feu moyen-vif pendant 5 minutes.
3. Ajouter les tomates et laisser mijoter 30 minutes à feu doux. Saler et poivrer.

Astuce : servir avec du riz basmati.`;

test('recette complète : titre, temps, ingrédients, étapes, notes', () => {
  const r = RP.parseRecipe(RECETTE, { autofix: true });
  assert.equal(r.name, 'Poulet au beurre');
  assert.equal(r.yield, '4 portions');
  assert.equal(r.prep, '15 min');
  assert.equal(r.cook, '40 min');
  assert.equal(r.ing.length, 6);
  assert.equal(r.ing[1], '125 ml (½ tasse) de yogourt nature');
  assert.equal(r.steps.length, 3);
  assert.match(r.steps[0], /^Dans un bol/);
  assert.match(r.notes, /riz basmati/);
  assert.equal(r.fixes.length, 1);
  assert.equal(RP.looksLikeRecipe(r), true);
});

test('une page sans recette n’est pas prise pour une recette', () => {
  const r = RP.parseRecipe('Avant-propos\n\nCe livre est né d’une envie de partager la cuisine de tous les jours avec ma famille et mes amis.', {});
  assert.equal(RP.looksLikeRecipe(r), false);
});

test('fractions perdues à l’OCR corrigées d’après les ml', () => {
  assert.equal(RP.fixConversions('125 ml (2 tasse) de lait', [], true), '125 ml (½ tasse) de lait');
  assert.equal(RP.fixConversions('15 ml (1 c. à soupe) de miel', [], true), '15 ml (1 c. à soupe) de miel');
  assert.equal(RP.fixConversions('125 ml (2 tasse) de lait', [], false), '125 ml (2 tasse) de lait');
});

test('JSON schema.org : durées ISO, sous-titres retirés, source', () => {
  const r = RP.parseRecipe(RECETTE, { autofix: true });
  const ld = RP.buildLD(Object.assign({}, r, { ing: ['# Marinade'].concat(r.ing), tags: 'four, Mon livre', source: 'Mon livre, p. 3' }), { inlineSource: true });
  assert.equal(ld.prepTime, 'PT15M');
  assert.equal(ld.cookTime, 'PT40M');
  assert.equal(ld.recipeIngredient.length, 6);
  assert.equal(ld.recipeInstructions.length, 3);
  assert.equal(ld.keywords, 'four, Mon livre');
  assert.match(ld.description, /Source : Mon livre, p\. 3$/);
  assert.equal(RP.toISO('1 h 30'), 'PT1H30M');
  assert.equal(RP.toISO('PT5M'), 'PT5M');
});

test('table des matières : titres et pages', () => {
  assert.deepEqual(plain(RP.tocEntries('Poulet au beurre ..... 31\nSoupe à l\'oignon P. 45\nVoir aussi page 3')),
    [{ title: 'Poulet au beurre', page: 31 }, { title: "Soupe à l'oignon", page: 45 }]);
  assert.equal(RP.keyOf('Crème brûlée !'), 'cremebrulee');
  assert.equal(RP.unglue('Pouletau beurre', 'poulet au beurre et riz'), 'Poulet au beurre');
});

test('mise en page : tableau quantité | ingrédient', () => {
  const it = (x, y, s) => ({ x, y, w: s.length * 6, h: 12, s });
  const out = LAYOUT.layoutPage([it(50, 100, '2'), it(120, 100, 'gousses d’ail hachées'), it(50, 116, '3'), it(120, 116, 'œufs battus'), it(50, 132, '1'), it(120, 132, 'oignon émincé')]);
  assert.deepEqual(plain(out.lines), ['• 2 gousses d’ail hachées', '• 3 œufs battus', '• 1 oignon émincé']);
});

test('site web : adresse du site, même site', () => {
  assert.deepEqual(plain(WEB.normSite('www.Exemple.com/livres')), { origin: 'https://www.exemple.com', host: 'www.exemple.com', base: 'exemple.com' });
  assert.equal(WEB.normSite('pas une adresse'), null);
  const site = WEB.normSite('exemple.com');
  assert.equal(WEB.sameSite('https://blog.exemple.com/a', site), true);
  assert.equal(WEB.sameSite('https://faux-exemple.com/a', site), false);
});

test('site web : plan du site et robots.txt', () => {
  const p = WEB.sitemapParse('<?xml version="1.0"?><sitemapindex><sitemap><loc>https://x.com/post-sitemap.xml</loc></sitemap><sitemap><loc><![CDATA[https://x.com/recipe-sitemap.xml]]></loc></sitemap></sitemapindex>');
  assert.equal(p.index, true);
  assert.deepEqual(plain(p.locs), ['https://x.com/post-sitemap.xml', 'https://x.com/recipe-sitemap.xml']);
  const u = WEB.sitemapParse('<urlset><url><loc>https://x.com/a?b=1&amp;c=2</loc><image:image><image:loc>https://x.com/i.jpg</image:loc></image:image></url></urlset>');
  assert.equal(u.index, false);
  assert.deepEqual(plain(u.locs), ['https://x.com/a?b=1&c=2']);
  assert.deepEqual(plain(WEB.robotsSitemaps('User-agent: *\nDisallow: /wp-admin/\nSitemap: https://x.com/sitemap_index.xml\n')), ['https://x.com/sitemap_index.xml']);
  assert.equal(WEB.childRank('https://x.com/recipe-sitemap.xml'), 2);
  assert.equal(WEB.childRank('https://x.com/post_tag-sitemap.xml'), -1);
});

test('site web : rapprochement titre ↔ adresse', () => {
  const idx = WEB.buildIndex(['https://x.com/recettes/poulet-au-beurre/', 'https://x.com/recettes/poulet-au-beurre-vegan/', 'https://x.com/categorie/poulet/',
    'https://x.com/recettes/12345-soupe-a-l-oignon-gratinee.html', 'https://x.com/recettes/gaspacho/', 'https://x.com/a-propos/']);
  const best = t => (WEB.match(t, idx)[0] || {}).url;
  assert.equal(best('Poulet au beurre'), 'https://x.com/recettes/poulet-au-beurre/');
  assert.equal(best('Soupe à l’oignon gratinée'), 'https://x.com/recettes/12345-soupe-a-l-oignon-gratinee.html');
  assert.equal(best('GASPACHO'), 'https://x.com/recettes/gaspacho/');
  assert.equal(best('Tarte aux pommes'), undefined);
  assert.equal(best('Gaspacho andalou'), undefined);
  assert.ok(WEB.sim('Poulet au beurre', 'Poulet au beurre facile') >= 0.6);
  assert.ok(WEB.sim('Poulet', 'Poulet au beurre') < 0.6);
});

test('site web : lecture de la recette d’une page (JSON-LD)', () => {
  const page = '<html><head><script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebSite","name":"X"},{"@type":["Recipe"],"name":"Poulet au beurre &amp; riz","image":{"@type":"ImageObject","url":"https://x.com/p.jpg"},"recipeYield":["4","4 portions"],"prepTime":"PT15M","recipeIngredient":["800 g de poulet","125 ml de yogourt","2 gousses d&#39;ail"],"recipeInstructions":[{"@type":"HowToSection","name":"Marinade","itemListElement":[{"@type":"HowToStep","text":"<p>Mélanger.</p>"}]},{"@type":"HowToStep","text":"Cuire 30 minutes."}],"review":[{"a":1}]}]}</script></head></html>';
  const ld = WEB.extractRecipeLD(page);
  assert.ok(ld && !('review' in ld));
  assert.deepEqual(plain(WEB.ldToRec(ld)), { name: 'Poulet au beurre & riz', desc: '', yield: '4 portions', prep: 'PT15M', cook: '', total: '',
    ing: ['800 g de poulet', '125 ml de yogourt', "2 gousses d'ail"], steps: ['# Marinade', 'Mélanger.', 'Cuire 30 minutes.'], image: 'https://x.com/p.jpg' });
  assert.equal(WEB.extractRecipeLD('<script type="application/ld+json">{"@type":"Article","name":"x"}</script>'), null);
  assert.equal(WEB.extractRecipeLD('<script type="application/ld+json">{pas du json</script>'), null);
  assert.deepEqual(plain(WEB.ldToRec({ name: 'A', recipeIngredient: ['a'], recipeInstructions: 'Un.<br>Deux.' }).steps), ['Un.', 'Deux.']);
});

console.log('\n' + n + ' tests réussis');
