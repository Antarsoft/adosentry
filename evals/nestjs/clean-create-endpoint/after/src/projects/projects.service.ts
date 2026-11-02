import { Injectable } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { CreateProjectDto } from './dto/create-project.dto';
import { Project } from './project.entity';
import { ProjectMember } from './project-member.entity';

@Injectable()
export class ProjectsService {
  constructor(private readonly dataSource: DataSource) {}

  listForOwner(ownerId: string) {
    return this.dataSource.getRepository(Project).find({ where: { ownerId }, take: 100, order: { createdAt: 'DESC' } });
  }

  create(dto: CreateProjectDto, ownerId: string) {
    return this.dataSource.transaction(async (manager) => {
      const project = await manager.save(
        manager.create(Project, { name: dto.name, description: dto.description ?? null, ownerId }),
      );
      await manager.save(manager.create(ProjectMember, { projectId: project.id, userId: ownerId, role: 'owner' }));
      return project;
    });
  }
}
