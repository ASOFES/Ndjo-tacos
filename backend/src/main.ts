import { config } from 'dotenv';
config();
import helmet from 'helmet';
import { NestFactory } from '@nestjs/core';
import { NestExpressApplication } from '@nestjs/platform-express';
import { join } from 'path';
import { AppModule } from './app.module';
import { isPrivateHttpOrigin, lanInfo } from './ops/lan';

async function bootstrap() {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    rawBody: true,
  });
  const production = process.env.NODE_ENV === 'production';
  if (production) {
    app.set('trust proxy', 1);
  }
  app.use(
    helmet({
      contentSecurityPolicy: production,
      hsts: production,
      crossOriginResourcePolicy: { policy: 'cross-origin' },
    }),
  );
  const http = app.getHttpAdapter().getInstance();
  const port = Number(process.env.PORT ?? 3000);
  const appPort = Number(process.env.WEB_PORT ?? 5192);
  http.get('/health', (_req: unknown, res: { json: (body: unknown) => void }) => {
    res.json({ ok: true, service: 'ndjo-tacos-api' });
  });
  http.get('/lan', (_req: unknown, res: { json: (body: unknown) => void }) => {
    res.json(lanInfo(port, appPort));
  });
  if (production) {
    app.use((req: { url?: string; secure?: boolean; headers: Record<string, unknown> }, res: { status: (n: number) => { json: (v: unknown) => void } }, next: () => void) => {
      const path = String(req.url ?? '').split('?')[0];
      if (path === '/health' || path === '/lan') return next();
      const proto = String(req.headers['x-forwarded-proto'] ?? '');
      if (req.secure || proto === 'https') return next();
      return res.status(400).json({ message: 'HTTPS obligatoire en production' });
    });
  }
  const origins = (process.env.CORS_ORIGIN ?? '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
  app.enableCors({
    origin: (origin, callback) => {
      if (!origin) return callback(null, true);
      if (origins.includes(origin)) return callback(null, true);
      if (isPrivateHttpOrigin(origin)) return callback(null, true);
      try {
        const host = new URL(origin).hostname.toLowerCase();
        if (host.endsWith('.netlify.app')) return callback(null, true);
      } catch {
        return callback(new Error('Origine CORS refusée'), false);
      }
      return callback(new Error('Origine CORS refusée'), false);
    },
    credentials: true,
    allowedHeaders: ['Content-Type', 'Authorization', 'Accept'],
    methods: ['GET', 'HEAD', 'PUT', 'PATCH', 'POST', 'DELETE', 'OPTIONS'],
  });
  app.useStaticAssets(join(process.cwd(), 'uploads'), { prefix: '/uploads/' });
  await app.listen(port, '0.0.0.0');
  const lan = lanInfo(port, appPort);
  console.log(`NDJO TACOS API prête sur http://localhost:${port}`);
  for (const url of lan.apiUrls) {
    console.log(`LAN API  ${url}`);
  }
  for (const url of lan.appUrls) {
    console.log(`LAN APP  ${url}`);
  }
}

bootstrap();
