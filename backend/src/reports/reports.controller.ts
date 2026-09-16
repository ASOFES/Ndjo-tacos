import { Controller, Get, Query, UseGuards } from '@nestjs/common';
import { JwtGuard } from '../auth/jwt.guard';
import { AccessGuard } from '../auth/access.guard';
import { RequirePermission } from '../auth/require-permission.decorator';
import { ReportsService } from './reports.service';

@Controller('reports')
@UseGuards(JwtGuard, AccessGuard)
export class ReportsController {
  constructor(private readonly reports: ReportsService) {}

  @Get()
  @RequirePermission('rapports.voir')
  build(
    @Query('establishmentId') establishmentId?: string,
    @Query('period') period?: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
  ) {
    return this.reports.build({ establishmentId, period, from, to });
  }
}
