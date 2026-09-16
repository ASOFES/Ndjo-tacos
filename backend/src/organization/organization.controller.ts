import {
  Body,
  Controller,
  Get,
  Param,
  Post,
  Put,
  Query,
  Req,
  UseGuards,
} from '@nestjs/common';
import { PrismaService } from '../prisma.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';

@Controller()
@UseGuards(JwtGuard, AccessGuard)
export class OrganizationController {
  constructor(private readonly prisma: PrismaService) {}

  @Post('establishments')
  @RequirePermission('admin.ecrire')
  createEstablishment(@Body() body: any, @Req() req: { user: { sub: string } }) {
    return this.saveEstablishment(body, req.user.sub, 'CREER');
  }

  @Put('establishments/:id')
  @RequirePermission('admin.ecrire')
  updateEstablishment(
    @Param('id') id: string,
    @Body() body: any,
    @Req() req: { user: { sub: string } },
  ) {
    return this.saveEstablishment({ ...body, id }, req.user.sub, 'MODIFIER');
  }

  @Get('departments')
  @RequirePermission('users.voir', 'admin.ecrire')
  departments(@Query('establishmentId') establishmentId: string) {
    return this.prisma.department.findMany({
      where: { establishmentId },
      include: { _count: { select: { users: true } } },
      orderBy: { name: 'asc' },
    });
  }

  @Post('departments')
  @RequirePermission('admin.ecrire')
  async createDepartment(@Body() body: any, @Req() req: { user: { sub: string } }) {
    const department = await this.prisma.department.create({
      data: {
        name: body.name,
        establishmentId: body.establishmentId,
        status: body.status ?? 'ACTIF',
      },
    });
    await this.audit(req.user.sub, 'CREER', 'DEPARTEMENT', department.name);
    return department;
  }

  @Put('departments/:id')
  @RequirePermission('admin.ecrire')
  updateDepartment(@Param('id') id: string, @Body() body: any) {
    return this.prisma.department.update({
      where: { id },
      data: { name: body.name, status: body.status },
    });
  }

  @Get('users')
  @RequirePermission('users.voir')
  async users(@Query('establishmentId') establishmentId?: string) {
    const users = await this.prisma.user.findMany({
      where: establishmentId ? { establishmentId } : undefined,
      include: {
        establishment: true,
        department: true,
      },
      orderBy: { name: 'asc' },
    });
    return users.map((user) => this.safe(user));
  }

  @Post('users')
  @RequirePermission('users.creer')
  async createUser(@Body() body: any, @Req() req: { user: { sub: string } }) {
    const bcrypt = await import('bcryptjs');
    const user = await this.prisma.user.create({
      data: {
        name: body.name,
        username: body.username,
        passwordHash: await bcrypt.hash(body.password ?? 'ndjo123', 10),
        role: body.role,
        phone: body.phone,
        email: body.email,
        photoUrl: body.photoUrl,
        establishmentId: body.establishmentId,
        departmentId: body.departmentId || null,
        status: body.status ?? 'ACTIF',
      },
      include: { establishment: true, department: true },
    });
    await this.audit(req.user.sub, 'CREER', 'UTILISATEUR', `${user.name} (${user.role})`);
    return this.safe(user);
  }

  @Put('users/:id')
  @RequirePermission('users.creer')
  async updateUser(
    @Param('id') id: string,
    @Body() body: any,
    @Req() req: { user: { sub: string } },
  ) {
    const bcrypt = await import('bcryptjs');
    const user = await this.prisma.user.update({
      where: { id },
      data: {
        name: body.name,
        role: body.role,
        phone: body.phone,
        photoUrl: body.photoUrl,
        establishmentId: body.establishmentId,
        departmentId: body.departmentId || null,
        status: body.status,
        ...(body.password
          ? { passwordHash: await bcrypt.hash(body.password, 10) }
          : {}),
      },
      include: { establishment: true, department: true },
    });
    await this.audit(req.user.sub, 'MODIFIER', 'UTILISATEUR', user.name);
    return this.safe(user);
  }

  private async saveEstablishment(body: any, userId: string, action: string) {
    const data = {
      code: body.code,
      name: body.name,
      type: body.type ?? 'Restaurant',
      address: body.address,
      phone: body.phone,
      email: body.email,
      manager: body.manager,
      latitude: body.latitude,
      longitude: body.longitude,
      hours: body.hours,
      deliveryZone: body.deliveryZone,
      status: body.status ?? 'ACTIF',
    };
    const establishment = body.id
      ? await this.prisma.establishment.update({ where: { id: body.id }, data })
      : await this.prisma.establishment.create({ data });
    await this.audit(userId, action, 'ETABLISSEMENT', establishment.name);
    return establishment;
  }

  private safe(user: any) {
    const { passwordHash, ...rest } = user;
    return rest;
  }

  private audit(userId: string, action: string, entity: string, details: string) {
    return this.prisma.auditLog.create({ data: { userId, action, entity, details } });
  }
}
