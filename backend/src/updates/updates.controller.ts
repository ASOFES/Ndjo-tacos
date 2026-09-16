import { Controller, Get, Query } from '@nestjs/common';
import { UpdatesService } from './updates.service';

@Controller('updates')
export class UpdatesController {
  constructor(private readonly updates: UpdatesService) {}

  @Get('app')
  app(
    @Query('platform') platform = 'web',
    @Query('build') build = '1',
  ) {
    return this.updates.checkApp(platform, Number(build));
  }

  @Get('catalog')
  catalog(
    @Query('establishmentId') establishmentId: string,
    @Query('sinceVersion') sinceVersion?: string,
  ) {
    return this.updates.catalog(establishmentId, sinceVersion);
  }

  @Get('config')
  config(@Query('establishmentId') establishmentId: string) {
    return this.updates.config(establishmentId);
  }
}
