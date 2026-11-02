import { Injectable } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { Project } from './project.entity';

@Injectable()
export class ProjectsService {
  constructor(private readonly dataSource: DataSource) {}

  listForOwner(ownerId: string) {
    return this.dataSource.getRepository(Project).find({ where: { ownerId }, take: 100, order: { createdAt: 'DESC' } });
  }
}
