package com.xcurenet.pop3reader.model;

import lombok.Builder;
import lombok.Data;

import javax.mail.Message;
import java.util.Date;

@Data
@Builder
public class MailData {
	private String messageId;
	private String from;
	private String subject;
	private Date sentDate;
	private String body;
	private Message msg;
}
