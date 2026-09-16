import { Body, Controller, Get, Param, Put, Req, UseGuards } from '@nestjs/common';
import { JwtGuard } from './jwt.guard';
import { AccessGuard } from './access.guard';
import { RequirePermission } from './require-permission.decorator';
import { PermissionService } from './permission.service';

@Controller()
@UseGuards(JwtGuard, AccessGuard)
export class PermissionsController {
  constructor(private readonly permissions: PermissionService) {}

  @Get('permissions')
  @RequirePermission('admin.ecrire', 'users.creer')
  list() {
    return this.permissions.matrix();
  }

  @Put('roles/:role/permissions')
  @RequirePermission('admin.ecrire')
  save(
    @Param('role') role: string,
    @Body() body: { keys?: string[] },
    @Req() req: { user: { sub: string } },
  ) {
    return this.permissions.setRoleKeys(role, body.keys ?? [], req.user.sub);
  }
}
