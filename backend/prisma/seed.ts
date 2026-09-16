import { PrismaClient } from '@prisma/client';
import * as bcrypt from 'bcryptjs';
import { createHash } from 'crypto';
import {
  DEFAULT_ROLE_PERMISSIONS,
  PERMISSION_CATALOG,
} from '../src/auth/permission.catalog';

const prisma = new PrismaClient();

async function main() {
  const passwordHash = await bcrypt.hash('admin123', 10);

  const centre = await prisma.establishment.upsert({
    where: { code: 'NDJ-01' },
    update: {},
    create: {
      code: 'NDJ-01',
      name: 'NDJO TACOS Centre',
      type: 'Restaurant',
      address: 'Avenue du Commerce, Centre-ville',
      phone: '+243 800 000 001',
    },
  });

  const kenya = await prisma.establishment.upsert({
    where: { code: 'NDJ-02' },
    update: {},
    create: {
      code: 'NDJ-02',
      name: 'NDJO TACOS Kenya',
      type: 'Restaurant',
      address: 'Quartier Kenya',
      phone: '+243 800 000 002',
    },
  });

  await prisma.user.upsert({
    where: { username: 'admin' },
    update: { passwordHash },
    create: {
      name: 'Super Administrateur',
      username: 'admin',
      passwordHash,
      role: 'SUPER_ADMIN',
      establishmentId: centre.id,
    },
  });

  const categories = [
    { name: 'Tacos' },
    { name: 'Burgers' },
    { name: 'Accompagnements' },
    { name: 'Boissons' },
    { name: 'Ingrédients' },
  ];

  const categoryIds: Record<string, string> = {};
  for (const item of categories) {
    const existing = await prisma.category.findFirst({
      where: { establishmentId: centre.id, name: item.name },
    });
    const row =
      existing ??
      (await prisma.category.create({
        data: { name: item.name, establishmentId: centre.id },
      }));
    categoryIds[item.name] = row.id;
  }

  const products = [
    { code: 'TAC-POU', name: 'Tacos poulet', category: 'Tacos', subcategory: 'Poulet', format: '500 g', volume: '500 g', priceBuy: 7000, priceSell: 15000, unit: 'pièce', kind: 'VENTE', supplier: 'Cuisine NDJO' },
    { code: 'TAC-VIA', name: 'Tacos viande', category: 'Tacos', subcategory: 'Viande', format: '500 g', volume: '500 g', priceBuy: 7500, priceSell: 16000, unit: 'pièce', kind: 'VENTE', supplier: 'Cuisine NDJO' },
    { code: 'TAC-MIX', name: 'Tacos mixte', category: 'Tacos', subcategory: 'Mixte', format: '500 g', volume: '500 g', priceBuy: 8000, priceSell: 17000, unit: 'pièce', kind: 'VENTE', supplier: 'Cuisine NDJO' },
    { code: 'BUR-CLA', name: 'Burger classique', category: 'Burgers', subcategory: 'Boeuf', format: 'Unitaire', volume: '1', priceBuy: 4000, priceSell: 7500, unit: 'pièce', kind: 'VENTE', supplier: 'Cuisine NDJO' },
    { code: 'FRI-150', name: 'Frites', category: 'Accompagnements', subcategory: 'Pomme de terre', format: '150 g', volume: '150 g', priceBuy: 800, priceSell: 5000, unit: 'portion', kind: 'VENTE', supplier: 'Cuisine NDJO' },
    { code: 'BOI-COC', name: 'Coca-Cola 330 ml', category: 'Boissons', subcategory: 'Gazeuse', format: '330 ml', volume: '330 ml', priceBuy: 1000, priceSell: 1500, unit: 'bouteille', kind: 'VENTE', supplier: 'Bracongo' },
    { code: 'BOI-FAN', name: 'Fanta 330 ml', category: 'Boissons', subcategory: 'Gazeuse', format: '330 ml', volume: '330 ml', priceBuy: 1000, priceSell: 1500, unit: 'bouteille', kind: 'VENTE', supplier: 'Bracongo' },
    { code: 'BOI-SPR', name: 'Sprite 330 ml', category: 'Boissons', subcategory: 'Gazeuse', format: '330 ml', volume: '330 ml', priceBuy: 1000, priceSell: 1500, unit: 'bouteille', kind: 'VENTE', supplier: 'Bracongo' },
    { code: 'ING-POU', name: 'Poulet', category: 'Ingrédients', subcategory: 'Viande', format: 'Vrac', volume: '1', priceBuy: 12000, priceSell: 0, unit: 'kg', kind: 'INGREDIENT', supplier: 'Ferme locale' },
    { code: 'ING-TOR', name: 'Tortilla', category: 'Ingrédients', subcategory: 'Pain', format: 'Unitaire', volume: '1', priceBuy: 400, priceSell: 0, unit: 'pièce', kind: 'INGREDIENT', supplier: 'Boulangerie' },
    { code: 'ING-FRO', name: 'Fromage', category: 'Ingrédients', subcategory: 'Laitier', format: 'Vrac', volume: '1', priceBuy: 15000, priceSell: 0, unit: 'kg', kind: 'INGREDIENT', supplier: 'Laiterie' },
    { code: 'ING-SAU', name: 'Sauce', category: 'Ingrédients', subcategory: 'Condiment', format: 'Vrac', volume: '1', priceBuy: 4000, priceSell: 0, unit: 'kg', kind: 'INGREDIENT', supplier: 'Cuisine NDJO' },
    { code: 'ING-LEG', name: 'Légumes', category: 'Ingrédients', subcategory: 'Frais', format: 'Vrac', volume: '1', priceBuy: 2000, priceSell: 0, unit: 'kg', kind: 'INGREDIENT', supplier: 'Marché' },
    { code: 'ING-FRX', name: 'Frites crues', category: 'Ingrédients', subcategory: 'Pomme de terre', format: 'Vrac', volume: '1', priceBuy: 3000, priceSell: 0, unit: 'kg', kind: 'INGREDIENT', supplier: 'Marché' },
    { code: 'ING-EMB', name: 'Emballage', category: 'Ingrédients', subcategory: 'Consommable', format: 'Unitaire', volume: '1', priceBuy: 200, priceSell: 0, unit: 'pièce', kind: 'INGREDIENT', supplier: 'Emballages Kin' },
  ];

  for (const product of products) {
    const fields = {
      name: product.name,
      unit: product.unit,
      priceBuy: product.priceBuy,
      priceSell: product.priceSell,
      kind: product.kind,
      subcategory: product.subcategory,
      format: product.format,
      volume: product.volume,
      supplier: product.supplier,
      categoryId: categoryIds[product.category],
    };
    await prisma.product.upsert({
      where: {
        establishmentId_code: { establishmentId: centre.id, code: product.code },
      },
      update: fields,
      create: {
        code: product.code,
        establishmentId: centre.id,
        ...fields,
      },
    });
  }

  const config = {
    commandes_en_ligne_ouvertes: 'true',
    livraison_active: 'true',
    message_accueil: 'Bienvenue chez NDJO TACOS',
    frais_livraison_defaut: '2000',
    tva_active: 'false',
    force_update_apk: 'false',
    maintenance_mode: 'false',
    whatsapp_actif: 'true',
  };

  for (const establishment of [centre, kenya]) {
    for (const [key, value] of Object.entries(config)) {
      await prisma.remoteConfig.upsert({
        where: {
          establishmentId_key: { establishmentId: establishment.id, key },
        },
        update: {},
        create: { establishmentId: establishment.id, key, value },
      });
    }
  }

  const zoneDefs = [
    { code: 'Z1', name: 'Centre-ville', fee: 2000 },
    { code: 'Z2', name: 'Kenya', fee: 3000 },
    { code: 'Z3', name: 'Est', fee: 5000 },
  ];
  const zoneIds: Record<string, string> = {};
  for (const establishment of [centre, kenya]) {
    for (const zone of zoneDefs) {
      const row = await prisma.deliveryZone.upsert({
        where: {
          establishmentId_code: { establishmentId: establishment.id, code: zone.code },
        },
        update: { name: zone.name, fee: zone.fee, status: 'ACTIF' },
        create: {
          ...zone,
          status: 'ACTIF',
          establishmentId: establishment.id,
        },
      });
      if (establishment.id === centre.id) zoneIds[zone.code] = row.id;
    }
  }

  const jean = await prisma.customer.upsert({
    where: {
      establishmentId_phone: { establishmentId: centre.id, phone: '+243 810 000 001' },
    },
    update: { name: 'Jean Mwamba', status: 'ACTIF' },
    create: {
      name: 'Jean Mwamba',
      phone: '+243 810 000 001',
      email: 'jean@ndjo.test',
      establishmentId: centre.id,
    },
  });
  const existingAddresses = await prisma.customerAddress.count({ where: { customerId: jean.id } });
  if (existingAddresses === 0) {
    await prisma.customerAddress.createMany({
      data: [
        {
          customerId: jean.id,
          label: 'Maison',
          address: 'Avenue du Commerce, Centre-ville',
          zoneId: zoneIds.Z1,
          isDefault: true,
        },
        {
          customerId: jean.id,
          label: 'Travail',
          address: 'Quartier Kenya, avenue principale',
          zoneId: zoneIds.Z2,
          isDefault: false,
        },
      ],
    });
  }

  const deptNames = ['Administration', 'Caisse', 'Cuisine', 'Dépôt', 'Livraison'];
  const departments: Record<string, string> = {};
  for (const name of deptNames) {
    const row = await prisma.department.upsert({
      where: { establishmentId_name: { establishmentId: centre.id, name } },
      update: {},
      create: { name, establishmentId: centre.id },
    });
    departments[name] = row.id;
  }

  const staff = [
    { name: 'Amina Caisse', username: 'caissier', role: 'CAISSIER', department: 'Caisse' },
    { name: 'Joseph Magasin', username: 'magasin', role: 'MAGASINIER', department: 'Dépôt' },
    { name: 'Grace Cuisine', username: 'cuisine', role: 'CUISINIER', department: 'Cuisine' },
    { name: 'Patrick Livreur', username: 'livreur', role: 'LIVREUR', department: 'Livraison' },
    { name: 'Client NDJO', username: 'client', role: 'CLIENT', department: 'Administration' },
  ];
  for (const person of staff) {
    await prisma.user.upsert({
      where: { username: person.username },
      update: {},
      create: {
        name: person.name,
        username: person.username,
        passwordHash,
        role: person.role,
        establishmentId: centre.id,
        departmentId: departments[person.department],
      },
    });
  }

  const admin = await prisma.user.findUnique({ where: { username: 'admin' } });

  const supplierDefs = [
    { name: 'Ferme locale', phone: '+243 810 100 001', address: 'Marché central', email: 'ferme@ndjo.test' },
    { name: 'Bracongo', phone: '+243 810 100 002', address: 'Zone industrielle', email: 'bracongo@ndjo.test' },
    { name: 'Boulangerie', phone: '+243 810 100 003', address: 'Avenue du Pain', email: 'pain@ndjo.test' },
  ];
  for (const item of supplierDefs) {
    await prisma.supplier.upsert({
      where: { establishmentId_name: { establishmentId: centre.id, name: item.name } },
      update: item,
      create: { ...item, establishmentId: centre.id, status: 'ACTIF' },
    });
  }
  await prisma.user.updateMany({
    where: { username: 'livreur' },
    data: {
      availability: 'DISPONIBLE',
      phone: '+243 800 000 010',
      photoUrl: 'https://ui-avatars.com/api/?name=Patrick+Livreur&background=1B5E20&color=fff',
    },
  });

  const drinks = await prisma.product.findMany({
    where: { establishmentId: centre.id, code: { in: ['BOI-COC', 'BOI-SPR', 'BOI-FAN'] } },
  });
  for (const product of drinks) {
    const existingLot = await prisma.lot.findFirst({
      where: { establishmentId: centre.id, productId: product.id },
    });
    if (existingLot) continue;
    const lot = await prisma.lot.create({
      data: {
        number: `NDJ-${product.code}-20260913-001`,
        productId: product.id,
        establishmentId: centre.id,
        expiryDate: new Date('2027-03-13'),
        qtyInitial: 48,
        qtyCurrent: 48,
        priceBuy: product.priceBuy,
        priceSell: product.priceSell,
      },
    });
    await prisma.stockMovement.create({
      data: {
        number: `ENT-2026-${product.code}`,
        type: 'ENTREE',
        quantity: 48,
        motif: 'Stock initial',
        destination: 'Dépôt',
        productId: product.id,
        lotId: lot.id,
        establishmentId: centre.id,
        userId: admin!.id,
      },
    });
  }

  const existingVersion = await prisma.appVersion.findFirst({
    where: { version: '1.0.0', platform: 'web' },
  });
  if (!existingVersion) {
    await prisma.appVersion.create({
      data: {
        version: '1.0.0',
        buildNumber: 1,
        platform: 'web',
        notes: 'Première version — authentification, catalogue et mises à jour en ligne.',
        minBuild: 1,
        forceUpdate: false,
        status: 'PUBLIEE',
        publishedAt: new Date(),
      },
    });
  }

  const ingredients = await prisma.product.findMany({
    where: { establishmentId: centre.id, kind: 'INGREDIENT' },
  });
  const ingredientQty: Record<string, number> = {
    'ING-POU': 25,
    'ING-TOR': 80,
    'ING-FRO': 10,
    'ING-SAU': 8,
    'ING-LEG': 12,
    'ING-FRX': 20,
    'ING-EMB': 100,
  };
  for (const product of ingredients) {
    const existingLot = await prisma.lot.findFirst({
      where: { establishmentId: centre.id, productId: product.id },
    });
    if (existingLot) continue;
    const qty = ingredientQty[product.code] ?? 10;
    const lot = await prisma.lot.create({
      data: {
        number: `NDJ-${product.code}-20260913-001`,
        productId: product.id,
        establishmentId: centre.id,
        expiryDate: new Date('2026-09-30'),
        qtyInitial: qty,
        qtyCurrent: qty,
        priceBuy: product.priceBuy,
        priceSell: 0,
      },
    });
    await prisma.stockMovement.create({
      data: {
        number: `ENT-2026-${product.code}`,
        type: 'ENTREE',
        quantity: qty,
        motif: 'Stock initial cuisine',
        destination: 'Dépôt',
        productId: product.id,
        lotId: lot.id,
        establishmentId: centre.id,
        userId: admin!.id,
      },
    });
  }

  const byCode = Object.fromEntries(ingredients.map((item) => [item.code, item]));
  for (const code of ['TAC-POU', 'TAC-VIA', 'TAC-MIX']) {
    const dish = await prisma.product.findUnique({
      where: { establishmentId_code: { establishmentId: centre.id, code } },
    });
    if (!dish || !byCode['ING-POU'] || !byCode['ING-TOR']) continue;
    const protein = code === 'TAC-MIX' ? 0.08 : 0.15;
    const lines = [
      { ingredientId: byCode['ING-POU'].id, quantity: protein, unit: 'kg' },
      { ingredientId: byCode['ING-TOR'].id, quantity: 1, unit: 'pièce' },
      { ingredientId: byCode['ING-FRO'].id, quantity: 0.03, unit: 'kg' },
      { ingredientId: byCode['ING-SAU'].id, quantity: 0.02, unit: 'kg' },
      { ingredientId: byCode['ING-LEG'].id, quantity: 0.05, unit: 'kg' },
      { ingredientId: byCode['ING-FRX'].id, quantity: 0.15, unit: 'kg' },
      { ingredientId: byCode['ING-EMB'].id, quantity: 1, unit: 'pièce' },
    ];
    await prisma.recipe.upsert({
      where: { productId: dish.id },
      update: { items: { deleteMany: {}, create: lines } },
      create: {
        productId: dish.id,
        establishmentId: centre.id,
        items: { create: lines },
      },
    });
  }

  const devices = [
    { name: 'Caisse Centre 01', role: 'CAISSIER', status: 'A_JOUR' },
    { name: 'Tablette Cuisine', role: 'CUISINIER', status: 'A_JOUR' },
    { name: 'Téléphone Livreur Patrick', role: 'LIVREUR', status: 'EN_ATTENTE' },
  ];
  for (const device of devices) {
    const id = createHash('sha1')
      .update(`${centre.id}:${device.name}`)
      .digest('hex')
      .slice(0, 24);
    await prisma.deviceDeployment.upsert({
      where: { id },
      update: {},
      create: {
        id,
        deviceName: device.name,
        role: device.role,
        appBuild: 1,
        status: device.status,
        establishmentId: centre.id,
      },
    });
  }

  for (const item of PERMISSION_CATALOG) {
    await prisma.permission.upsert({
      where: { key: item.key },
      update: { label: item.label },
      create: item,
    });
  }
  const permissionRows = await prisma.permission.findMany();
  const permissionId = Object.fromEntries(permissionRows.map((row) => [row.key, row.id]));
  for (const [role, keys] of Object.entries(DEFAULT_ROLE_PERMISSIONS)) {
    const existing = await prisma.rolePermission.count({ where: { role } });
    if (existing > 0) continue;
    for (const key of keys) {
      const id = permissionId[key];
      if (!id) continue;
      await prisma.rolePermission.create({ data: { role, permissionId: id } });
    }
  }

  console.log('Seed NDJO TACOS OK');
  console.log('Connexion: admin / admin123');
}

main()
  .finally(async () => {
    await prisma.$disconnect();
  });
