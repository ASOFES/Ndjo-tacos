import {
  Body,
  Controller,
  Get,
  Post,
  Req,
  UnauthorizedException,
  UseGuards,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { createHash, randomBytes } from 'crypto';
import { PrismaService } from '../prisma.service';
import { JwtGuard } from './jwt.guard';
import { PermissionService } from './permission.service';
import * as bcrypt from 'bcryptjs';

@Controller('auth')
export class AuthController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
    private readonly permissions: PermissionService,
  ) {}

  @Post('login')
  async login(@Body() body: { username: string; password: string }) {
    const user = await this.prisma.user.findUnique({
      where: { username: body.username },
      include: { establishment: true },
    });
    if (!user || !(await bcrypt.compare(body.password, user.passwordHash))) {
      throw new UnauthorizedException('Identifiants incorrects');
    }
    if (user.status !== 'ACTIF') {
      throw new UnauthorizedException('Compte désactivé');
    }
    if (user.role === 'LIVREUR' && user.availability !== 'EN_LIVRAISON') {
      await this.prisma.user.update({
        where: { id: user.id },
        data: { availability: 'DISPONIBLE' },
      });
      user.availability = 'DISPONIBLE';
    }
    return this.issueSession(user);
  }

  @Post('refresh')
  async refresh(@Body() body: { refreshToken?: string }) {
    const raw = body.refreshToken ?? '';
    const tokenHash = hashToken(raw);
    const stored = await this.prisma.refreshToken.findUnique({
      where: { tokenHash },
      include: { user: { include: { establishment: true } } },
    });
    if (!stored || stored.revokedAt || stored.expiresAt < new Date()) {
      throw new UnauthorizedException('Session expirée');
    }
    await this.prisma.refreshToken.update({
      where: { id: stored.id },
      data: { revokedAt: new Date() },
    });
    if (stored.user.status !== 'ACTIF') {
      throw new UnauthorizedException('Compte désactivé');
    }
    if (stored.user.role === 'LIVREUR' && stored.user.availability !== 'EN_LIVRAISON') {
      await this.prisma.user.update({
        where: { id: stored.user.id },
        data: { availability: 'DISPONIBLE' },
      });
      stored.user.availability = 'DISPONIBLE';
    }
    return this.issueSession(stored.user);
  }

  @Post('logout')
  @UseGuards(JwtGuard)
  async logout(
    @Body() body: { refreshToken?: string },
    @Req() req: { user: { sub: string; role?: string } },
  ) {
    if (body.refreshToken) {
      await this.prisma.refreshToken.updateMany({
        where: { tokenHash: hashToken(body.refreshToken) },
        data: { revokedAt: new Date() },
      });
    }
    if (req.user?.role === 'LIVREUR') {
      await this.prisma.user.updateMany({
        where: { id: req.user.sub, availability: { not: 'EN_LIVRAISON' } },
        data: { availability: 'HORS_LIGNE' },
      });
    }
    return { ok: true };
  }

  /** Validation gestionnaire / admin pour une remise caisse au-delà du seuil auto. */
  @Post('validate-approver')
  @UseGuards(JwtGuard)
  async validateApprover(
    @Body() body: { username?: string; password?: string },
    @Req() req: { user: { sub: string } },
  ) {
    const username = String(body.username ?? '').trim();
    const password = String(body.password ?? '');
    if (!username || !password) {
      throw new UnauthorizedException('Identifiants requis');
    }
    const user = await this.prisma.user.findUnique({ where: { username } });
    if (!user || !(await bcrypt.compare(password, user.passwordHash))) {
      throw new UnauthorizedException('Identifiants incorrects');
    }
    if (user.status !== 'ACTIF') {
      throw new UnauthorizedException('Compte désactivé');
    }
    if (!['SUPER_ADMIN', 'ADMIN', 'GESTIONNAIRE'].includes(user.role)) {
      throw new UnauthorizedException('Rôle insuffisant pour valider une remise');
    }
    if (user.id === req.user.sub) {
      throw new UnauthorizedException('Un autre compte doit valider la remise');
    }
    return {
      id: user.id,
      name: user.name,
      username: user.username,
      role: user.role,
    };
  }

  @Get('me')
  @UseGuards(JwtGuard)
  async me(@Req() req: { user: { sub: string } }) {
    const user = await this.prisma.user.findUnique({
      where: { id: req.user.sub },
      include: { establishment: true },
    });
    return this.presentUser(user);
  }

  private async issueSession(user: any) {
    const accessToken = this.jwt.sign(
      {
        sub: user.id,
        username: user.username,
        role: user.role,
        establishmentId: user.establishmentId,
        typ: 'access',
      },
      { expiresIn: (process.env.JWT_ACCESS_TTL ?? '7d') as `${number}d` },
    );
    const refreshToken = randomBytes(48).toString('hex');
    const days = Number((process.env.JWT_REFRESH_TTL ?? '7d').replace('d', '')) || 7;
    await this.prisma.refreshToken.create({
      data: {
        tokenHash: hashToken(refreshToken),
        userId: user.id,
        expiresAt: new Date(Date.now() + days * 86400000),
      },
    });
    return {
      token: accessToken,
      refreshToken,
      expiresIn: process.env.JWT_ACCESS_TTL ?? '7d',
      user: await this.presentUser(user),
    };
  }

  private async presentUser(user: any) {
    return {
      id: user.id,
      name: user.name,
      username: user.username,
      role: user.role,
      phone: user.phone,
      photoUrl: user.photoUrl,
      availability: user.availability,
      establishmentId: user.establishmentId,
      permissions: await this.permissions.keysFor(user.role),
      establishment: user.establishment
        ? {
            id: user.establishment.id,
            code: user.establishment.code,
            name: user.establishment.name,
          }
        : null,
    };
  }
}

function hashToken(value: string) {
  return createHash('sha256').update(value).digest('hex');
}
